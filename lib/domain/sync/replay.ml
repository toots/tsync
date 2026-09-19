module Ek = Journal.Entry_key

module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File_store.S with type 'a io := 'a io

    val note_applied : Journal.Entry_key.t -> Journal.op list -> unit io

    (** Every entry this client has applied or published, as far back as it
        keeps them. *)
    val applied_keys : unit -> Journal.Entry_key.t list io

    val note_local : Journal.op list -> unit io
  end
end

module type S = sig
  type 'a io

  val reconcile : unit -> unit io
  val apply_foreign : on_changed:(string -> unit) -> unit -> int io
  val mark_handled : Journal.Entry_key.t list -> unit io
  val unapplied : unit -> (Journal.Entry_key.t * string) list
end

module type OVER = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (F : File_ops.S with type 'a io := 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Bounded : Bounded.S with type 'a io := 'a Io.t)
    (Js : JOURNAL with type 'a io := 'a Io.t)
    (W : Wal.OVER with type 'a io := 'a Io.t)
    (Sm : Staged_manifest.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* Per domain rather than per application of the functor below: the poller
     that steps an entry aside and the engine that reports it each apply it. *)
  let stepped_aside : (string, (string, string) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 4

  let stepped_aside_for domain =
    match Hashtbl.find_opt stepped_aside domain with
      | Some entries -> entries
      | None ->
          let entries = Hashtbl.create 4 in
          Hashtbl.replace stepped_aside domain entries;
          entries

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) =
  struct
    module Js = Js.Make (C)
    module Lk = Logical_key.Make (C)
    module J = Journal.Make (C)
    module W = W.Make (C)
    module Mfs = Sm.Make (C)

    let full_key rel = Lk.file rel

    (* Bounded rather than [iter_p]: recovery can face a journal of any size, and
       a promise per entry up front is both memory and a request storm. Module
       scope, so two overlapping recoveries share the one bound. *)
    let journal_reads = Bounded.create ~max:32 ()

    (* Keys another client has touched since [entry_key]: our ops for those lose,
       because the other client's change is newer than the one we never finished
       publishing. *)
    let overridden_since entry_key =
      let my_uuid = J.client_uuid () in
      let* newer = Js.list_journal_keys ~start_after:entry_key () in
      let touched = Hashtbl.create 16 in
      let+ () =
        Bounded.iter_with journal_reads
          (fun ek ->
            if Ek.client_uuid ek = my_uuid then return_unit
            else
              let+ entry = Js.get_journal_entry ek in
              match entry with
                | None -> ()
                | Some ops ->
                    List.iter
                      (fun k -> Hashtbl.replace touched k ())
                      (Journal.keys_of_ops ops))
          newer
      in
      touched

    let apply_op op =
      Io.catch
        (fun () ->
          match op with
            | `Put _ ->
                (* Handled by [resume_put], which needs the record's own key. *)
                return_unit
            | `Delete rel -> F.apply_delete (Lk.file rel)
            | `Mkdir (rel, _) -> F.mkdir (Lk.dir rel)
            | `Rmdir (rel, _) -> F.rmdir (Lk.dir rel)
            | `Rename { Journal.dst; src; _ } ->
                F.rename ~src:(full_key src) ~dst:(full_key dst))
        (fun exn ->
          Log.err "replay %s: %s"
            (String.concat ", " (Journal.keys_of_op op))
            (Printexc.to_string exn);
          return_unit)

    (* A record whose bytes are up owes only the entry. Asking the backend is what
       makes the publish idempotent across a crash in either direction. *)
    let finish_executed key (r : Wal.record) =
      let* published = Js.journal_entry_published key in
      if published then W.complete key
      else
        let* (_ : Ek.t) = Js.write_journal_entry ~entry_key:key r.Wal.ops in
        let* () = Js.bump_cursor key in
        W.complete key

    (* Nothing was published, so the ops still have to happen. Metadata ops are
       re-applied and the entry published here; a put goes back through the queue
       under this same key, and the queue publishes it when the bytes land. *)
    let replay_unpublished key (r : Wal.record) =
      let short = Ek.to_string key in
      let* touched = overridden_since key in
      let ops =
        List.filter
          (fun op ->
            not (List.exists (Hashtbl.mem touched) (Journal.keys_of_op op)))
          r.Wal.ops
      in
      let skipped = List.length r.Wal.ops - List.length ops in
      if skipped > 0 then
        Log.info "%s: %d op(s) skipped — another client has since changed them"
          short skipped;
      match ops with
        | [] -> W.complete key
        | ops ->
            let puts, meta = Wal.partition_puts ops in
            (* Journal order matters: a rename must follow its create. *)
            let* () = iter_s apply_op meta in
            let* resumed =
              match puts with
                | [(`Put (rel, _) as op)] ->
                    F.resume_put (full_key rel) ~entry_key:key
                      ~record:{ r with Wal.ops = [op] }
                | _ -> return_false
            in
            if resumed then
              (* The queue owns the record from here: it publishes the entry and
                 drops the record when the upload lands. *)
              return_unit
            else if meta <> [] then
              let* (_ : Ek.t) = Js.write_journal_entry ~entry_key:key meta in
              let* () = Js.bump_cursor key in
              W.complete key
            else begin
              (* A put whose staged data is gone: the bytes it named cannot be
                 recovered, and publishing an entry for them would tell peers to
                 fetch something that was never uploaded. *)
              Log.info "%s: nothing staged, discarding" short;
              W.complete key
            end

    (* The local half of a prepared record has happened, so it goes back to
       whichever queue owes its backend half rather than being applied a second
       time.

       No {!overridden_since} here: the local side is already what this client
       holds, and publishing it is what brings the two back into agreement --
       skipping it would leave them apart with nothing left saying so. *)
    let resume_prepared key (r : Wal.record) =
      let puts, meta = Wal.partition_puts r.Wal.ops in
      match (puts, meta) with
        | [(`Put (rel, _) as op)], [] ->
            let* resumed =
              F.resume_put (full_key rel) ~entry_key:key
                ~record:{ r with Wal.ops = [op] }
            in
            if resumed then return_unit else W.complete key
        | [], _ :: _ -> F.resume_meta ~entry_key:key ~record:r
        | _ -> replay_unpublished key r

    let reconcile_record (key, (r : Wal.record)) =
      Io.catch
        (fun () ->
          match r.Wal.state with
            | Wal.Executed -> finish_executed key r
            | Wal.Prepared -> resume_prepared key r
            | Wal.Intent when Wal.is_metadata r ->
                let* () = iter_s F.redo_local r.Wal.ops in
                F.resume_meta ~entry_key:key
                  ~record:{ r with Wal.state = Wal.Prepared }
            | Wal.Intent -> replay_unpublished key r)
        (fun exn ->
          (* Left in place: a record that could not be reconciled is tried again
             next start, and stats reports it in the meantime. *)
          Log.err "reconcile %s: %s" (Ek.to_string key) (Printexc.to_string exn);
          W.note_failure key (Backend.classify exn) (Retry.reason exn))

    (* Staged data no record names: a crash between staging the content and
       recording the intent. Adopted under a new record, which is correct here
       precisely because no key exists for it yet. *)
    let adopt_unrecorded ~recorded =
      let* keys = Mfs.list () in
      iter_s
        (fun key ->
          if List.mem (Logical_key.path key) recorded then return_unit
          else begin
            Log.info "adopting staged upload for %s" (Logical_key.to_string key);
            Io.catch
              (fun () -> F.queue_put key)
              (fun exn ->
                Log.err "staged upload %s failed: %s"
                  (Logical_key.to_string key)
                  (Printexc.to_string exn);
                return_unit)
          end)
        keys

    let reconcile () =
      let* records = W.list () in
      if records <> [] then
        Log.info "reconciling %d unfinished record(s)" (List.length records);
      (* Sequential: journal order. *)
      let* () = iter_s reconcile_record records in
      let recorded =
        List.concat_map
          (fun (_, (r : Wal.record)) -> Journal.keys_of_ops r.Wal.ops)
          records
      in
      adopt_unrecorded ~recorded

    (* The keys this client has handled, loaded once and kept as entries are
       applied. *)
    let handled : (string, unit) Hashtbl.t option ref = ref None

    let handled_set () =
      match !handled with
        | Some set -> Io.return set
        | None ->
            let+ keys = Js.applied_keys () in
            let set = Hashtbl.create 1024 in
            List.iter (fun k -> Hashtbl.replace set (Ek.to_string k) ()) keys;
            handled := Some set;
            set

    let remember set ek = Hashtbl.replace set (Ek.to_string ek) ()

    (* Entries a rebuild has already read the effect of: remembered as handled so
       they are not applied on top of the mirror they are in. *)
    let mark_handled keys =
      let* set = handled_set () in
      iter_s
        (fun ek ->
          if Hashtbl.mem set (Ek.to_string ek) then return_unit
          else begin
            remember set ek;
            Js.note_applied ek []
          end)
        keys

    let window_ms = Int64.of_int (Applied_entries.keep_days * 86_400_000)

    (* A key says when its writer minted it, not when the store showed it. An
       entry can appear behind ones already applied -- a slow upload, a record
       published after a crash under its original key -- and a listing cut at the
       last-sync key would never see it. So every entry the memory reaches back
       to is checked against it instead. Older than the memory, an entry cannot
       be told from one handled and since forgotten, and is left alone; with no
       mark at all nothing has been handled, and the whole journal is due. *)
    let apply_foreign ~on_changed () =
      let my_uuid = J.client_uuid () in
      let* set = handled_set () in
      let horizon =
        match Js.read_last_sync_key () with
          | None -> None
          | Some _ ->
              Some
                (Int64.sub
                   (Int64.of_float (Unix.gettimeofday () *. 1000.))
                   window_ms)
      in
      let* keys = Js.list_journal_keys () in
      let keys =
        List.filter
          (fun ek ->
            (match horizon with
              | None -> true
              | Some h -> Int64.compare (Ek.timestamp_ms ek) h >= 0)
            && not (Hashtbl.mem set (Ek.to_string ek)))
          keys
      in
      let applied = ref 0 in
      let aside = stepped_aside_for C.domain_name in
      (* Entries are applied in order, so one failing the same way on every try
         would keep every later one from this client for good. It is left
         unhandled, which is what brings it back on the next pass, and said. *)
      let stepping_aside ek apply =
        Io.catch apply (fun exn ->
            if Retry.classify_in_order exn = Retry.Transient then Io.fail exn
            else begin
              if not (Hashtbl.mem aside (Ek.to_string ek)) then
                Log.err "%s: a peer's entry could not be applied here: %s"
                  (Ek.to_string ek) (Retry.reason exn);
              Hashtbl.replace aside (Ek.to_string ek) (Retry.reason exn);
              return_unit
            end)
      in
      let+ () =
        iter_s
          (fun ek ->
            stepping_aside ek @@ fun () ->
            let* () =
              if Ek.client_uuid ek = my_uuid then return_unit
              else
                let* entry = Js.get_journal_entry ek in
                match entry with
                  | None -> return_unit
                  | Some ops ->
                      let* () = F.apply_foreign_ops ops in
                      Hashtbl.remove aside (Ek.to_string ek);
                      (* After applying, so a reader of the kept entries never
                         meets one the mirror has not caught up with. *)
                      let* () = Js.note_applied ek ops in
                      remember set ek;
                      List.iter
                        (fun k ->
                          on_changed (Logical_key.to_string (full_key k)))
                        (Journal.keys_of_ops ops);
                      incr applied;
                      return_unit
            in
            (* Only after the entry applied cleanly, so a failure retries it rather
               than skipping it and diverging until a full resync. Never moved
               back: an entry behind the mark is the ordinary case here. *)
            (match Js.read_last_sync_key () with
              | Some mark when Ek.compare mark ek >= 0 -> ()
              | _ -> Js.write_last_sync_key ek);
            return_unit)
          keys
      in
      !applied

    let unapplied () =
      Hashtbl.fold
        (fun key why acc ->
          match Ek.of_string key with
            | Some ek -> (ek, why) :: acc
            | None -> acc)
        (stepped_aside_for C.domain_name)
        []
  end
end
