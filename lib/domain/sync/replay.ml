module Ek = Journal.Entry_key

(* What this needs below it. *)
module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write_journal_entry :
      ?entry_key:Journal.Entry_key.t ->
      Journal.op list ->
      Journal.Entry_key.t io

    val bump_cursor : Journal.Entry_key.t -> unit io

    val list_journal_keys :
      ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list io

    val get_journal_entry : Journal.Entry_key.t -> Journal.op list option io
    val note_applied : Journal.Entry_key.t -> Journal.op list -> unit io
    val journal_entry_published : Journal.Entry_key.t -> bool io
    val read_last_sync_key : unit -> Journal.Entry_key.t option
    val write_last_sync_key : Journal.Entry_key.t -> unit
  end
end

module type WAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val list : unit -> (Journal.Entry_key.t * Wal.record) list io
    val complete : Journal.Entry_key.t -> unit io
    val note_failure : Journal.Entry_key.t -> Retry.kind -> string -> unit io
  end
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val list : unit -> Logical_key.t list io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val iter_with : t -> ('a -> unit io) -> 'a list -> unit io
end

module Over
    (Io : Io.S)
    (Bounded : POOLS with type 'a io := 'a Io.t)
    (Js : JOURNAL with type 'a io := 'a Io.t)
    (W : WAL with type 'a io := 'a Io.t)
    (Sm : STAGED with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_some x = Io.return (Some x)
  let return_true = Io.return true
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

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
    let op_keys = Journal.keys_of_op
    let op_key op = List.hd (op_keys op)

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
                      (fun op ->
                        List.iter
                          (fun k -> Hashtbl.replace touched k ())
                          (op_keys op))
                      ops)
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
          Log.err "replay %s: %s" (op_key op) (Printexc.to_string exn);
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
        List.filter (fun op -> not (Hashtbl.mem touched (op_key op))) r.Wal.ops
      in
      let skipped = List.length r.Wal.ops - List.length ops in
      if skipped > 0 then
        Log.info "%s: %d op(s) skipped — another client has since changed them"
          short skipped;
      match ops with
        | [] -> W.complete key
        | ops ->
            let puts, meta =
              List.partition (function `Put _ -> true | _ -> false) ops
            in
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

    let reconcile_record (key, (r : Wal.record)) =
      Io.catch
        (fun () ->
          match r.Wal.state with
            | Wal.Executed -> finish_executed key r
            | Wal.Intent | Wal.Prepared -> replay_unpublished key r)
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
          if List.mem (F.rel_key key) recorded then return_unit
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
          (fun (_, (r : Wal.record)) -> List.map op_key r.Wal.ops)
          records
      in
      adopt_unrecorded ~recorded

    let apply_foreign ~on_changed () =
      let my_uuid = J.client_uuid () in
      let* keys =
        Js.list_journal_keys ?start_after:(Js.read_last_sync_key ()) ()
      in
      let applied = ref 0 in
      let+ () =
        iter_s
          (fun ek ->
            let* () =
              if Ek.client_uuid ek = my_uuid then return_unit
              else
                let* entry = Js.get_journal_entry ek in
                match entry with
                  | None -> return_unit
                  | Some ops ->
                      let* () = F.apply_foreign_ops ops in
                      (* After applying, so a reader of the kept entries never
                         meets one the mirror has not caught up with. *)
                      let* () = Js.note_applied ek ops in
                      List.iter
                        (fun op ->
                          on_changed
                            (Logical_key.to_string (full_key (op_key op))))
                        ops;
                      incr applied;
                      return_unit
            in
            (* Only after the entry applied cleanly, so a failure retries it rather
               than skipping it and diverging until a full resync. *)
            Js.write_last_sync_key ek;
            return_unit)
          keys
      in
      !applied
  end
end
