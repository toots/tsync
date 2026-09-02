module Ek = Journal.Entry_key

(* A domain's cursor is one object name, and a store caps writes to a single
   name at roughly one a second before answering 429. The cursor only moves
   forward, so a burst collapses to its newest: publish when the object has been
   quiet, defer and coalesce when it has not.

   Keyed by the object rather than held per functor application: {!Make} is
   applied in every module that touches the journal, and per-instantiation state
   would give each one its own debouncer with no flush reaching the others. Same
   reason as {!Journal.uuid_cache}. *)

(* Must stay above the one write a second a single name is allowed, or the
   coalescing trades a burst of 429s for a slower burst of them. *)
let cursor_flush_interval = ref 2.
let set_cursor_flush_interval s = cursor_flush_interval := s

module type S = sig
  type 'a io

  val rename_file :
    src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io

    val head_manifest_opt : key:Logical_key.t -> Backend.file_entry option io

  val write_journal_entry :
    ?entry_key:Journal.Entry_key.t ->
    Journal.op list ->
    Journal.Entry_key.t io

    val write_journal_entry_body :
    ?entry_key:Journal.Entry_key.t -> Bigstring.t -> Journal.Entry_key.t io

    val bump_cursor : Journal.Entry_key.t -> unit io

    val note_cursor : Journal.Entry_key.t -> unit

    val flush_cursor : unit -> unit io

  val fetch_cursor : unit -> Journal.Entry_key.t option io

    val wait_cursor_change : Journal.Entry_key.t option -> unit io

    val read_last_sync_key : unit -> Journal.Entry_key.t option

  val write_last_sync_key : Journal.Entry_key.t -> unit

    val list_journal_keys :
    ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list io

  val get_journal_entry : Journal.Entry_key.t -> Journal.op list option io

    val journal_entry_published : Journal.Entry_key.t -> bool io
end

module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Locks : Lock.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Manifests : Store.INODE with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  type cursor_state = {
    mutable pending : Ek.t option;
    mutable last_published : float;
    mutable timer_armed : bool;
    publish_lock : Locks.mutex;
  }

  let cursor_states : (string, cursor_state) Hashtbl.t = Hashtbl.create 4

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module J = Journal.Make (C)
    module St = Manifests.Make (C)
    module B = (val C.store : C.Store)

    let rename_file ~src_key ~dst_key = St.copy_manifest ~src_key ~dst_key
    let head_manifest_opt ~key = St.head_manifest ~key

    (* The one place an entry key becomes a backend key. Concatenating the prefix
       onto a bare entry key skips the month directory and silently misses. *)
    let journal_key entry_key =
      Stored_key.in_space ~prefix:C.journal_prefix (Ek.relative_path entry_key)

    let write_journal_entry_body ?entry_key body =
      let ek = match entry_key with Some k -> k | None -> J.entry_key () in
      let+ () = B.put ~key:(journal_key ek) ~data:body () in
      ek

    let write_journal_entry ?entry_key ops =
      write_journal_entry_body ?entry_key
        (Bigstring.of_string (Journal.encode ops))

    let cursor_state () =
      match
        Hashtbl.find_opt cursor_states (Stored_key.to_string C.cursor_key)
      with
        | Some s -> s
        | None ->
            let s =
              {
                pending = None;
                last_published = 0.;
                timer_armed = false;
                publish_lock = Locks.mutex ();
              }
            in
            Hashtbl.replace cursor_states (Stored_key.to_string C.cursor_key) s;
            s

    (* Serialized: a timer flush and a drain flush landing together would be two
       concurrent writes to the one object this exists to write less often. The
       clock restarts when the write lands, so the spacing is between writes. *)
    let publish_cursor s entry_key =
      Locks.with_lock s.publish_lock (fun () ->
          let+ () =
            B.put ~key:C.cursor_key
              ~data:(Bigstring.of_string (Ek.to_string entry_key))
              ()
          in
          s.last_published <- Unix.gettimeofday ())

    (* Forward-only: an older key arriving behind a newer one is already covered
       by it. *)
    let note s entry_key =
      match s.pending with
        | Some prev when Ek.compare prev entry_key >= 0 -> ()
        | Some _ | None -> s.pending <- Some entry_key

    let flush_cursor () =
      let s = cursor_state () in
      let pending = s.pending in
      s.pending <- None;
      s.timer_armed <- false;
      match pending with
        | None -> Io.return ()
        | Some entry_key ->
            Io.catch
              (fun () -> publish_cursor s entry_key)
              (fun exn ->
                (* Swallowed: this runs from a timer and from drain, and a dying
                   backend must not take either down. The entry is published
                   either way, and a peer that cannot bridge the gap resyncs. *)
                Log.err "bump_cursor: %s" (Printexc.to_string exn);
                Io.return ())

    let arm s =
      if not s.timer_armed then begin
        s.timer_armed <- true;
        Io.async (fun () ->
            let quiet_for = Unix.gettimeofday () -. s.last_published in
            let* () =
              Clock.sleep (max 0. (!cursor_flush_interval -. quiet_for))
            in
            flush_cursor ())
      end

    let bump_cursor entry_key =
      let s = cursor_state () in
      if Unix.gettimeofday () -. s.last_published >= !cursor_flush_interval then
        publish_cursor s entry_key
      else begin
        note s entry_key;
        arm s;
        Io.return ()
      end

    let note_cursor entry_key =
      let s = cursor_state () in
      note s entry_key;
      arm s

    (* How far this client has applied the shared journal. Local, because it says
       what *we* have caught up to, not what was published. *)
    let last_sync_file =
      Filename.concat C.data_dir ("last-sync-" ^ C.domain_name)

    let read_last_sync_key () =
      if Sys.file_exists last_sync_file then (
        try
          let ic = open_in last_sync_file in
          let s = input_line ic in
          close_in ic;
          Ek.of_string (String.trim s)
        with _ -> None)
      else None

    let write_last_sync_key key =
      try
        let oc = open_out last_sync_file in
        output_string oc (Ek.to_string key);
        close_out oc
      with exn ->
        Log.err "file_store: write_last_sync_key: %s" (Printexc.to_string exn)

    let fetch_cursor () =
      let+ body = B.get_opt ~key:C.cursor_key () in
      Option.bind body (fun b ->
          Ek.of_string (String.trim (Bigstring.to_string b)))

    (* The token is the body {!publish_cursor} writes, spelled the same way here:
       what a caller holds is the key, and what a store compares is the object. *)
    let wait_cursor_change last_seen =
      let last_seen =
        Option.map
          (fun ek ->
            Backend.Watch_token.of_body (Bigstring.of_string (Ek.to_string ek)))
          last_seen
      in
      B.watch ~key:C.cursor_key ~last_seen ()

    let list_journal_keys ?start_after () =
      let+ all = B.list_prefix ~prefix:C.journal_prefix () in
      List.filter_map
        (fun (e : Backend.file_entry) ->
          (* Entries sit in month directories ({!Ek.relative_path}); [of_string]
             takes the last segment. *)
            match Ek.of_string (Stored_key.to_string e.key) with
            | Some ek
              when match start_after with
                     | Some sa -> Ek.compare ek sa > 0
                     | None -> true ->
                Some ek
            | Some _ | None -> None)
        all
      (* Callers apply entries in the order returned, and applying two ops out of
         order diverges local state. Sorted here rather than trusted from the
         backend: a filesystem backend lists in readdir order, which is arbitrary. *)
      |> List.sort Ek.compare

    let get_journal_entry entry_key =
      let key = journal_key entry_key in
      Io.catch
        (fun () ->
          let+ d = B.get ~key () in
          Some (Journal.decode (Bigstring.to_string d)))
        (fun _ -> Io.return None)

    let journal_entry_published entry_key =
      let+ head = B.head_opt ~key:(journal_key entry_key) () in
      head <> None
  end
end
