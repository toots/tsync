open Lwt.Syntax
module Ek = Journal.Entry_key

(* A domain's cursor is one object name, and a store caps writes to a single
   name at roughly one a second before answering 429. The cursor only moves
   forward, so a burst collapses to its newest: publish when the object has been
   quiet, defer and coalesce when it has not.

   Keyed by the object rather than held per functor application: {!Make} is
   applied in every module that touches the journal, and per-instantiation state
   would give each one its own debouncer with no flush reaching the others. Same
   reason as {!Journal.uuid_cache}. *)
type cursor_state = {
  mutable pending : Ek.t option;
  mutable last_published : float;
  mutable timer_armed : bool;
  publish_lock : Lwt_mutex.t;
}

let cursor_states : (string, cursor_state) Hashtbl.t = Hashtbl.create 4

(* Must stay above the one write a second a single name is allowed, or the
   coalescing trades a burst of 429s for a slower burst of them. *)
let cursor_flush_interval = ref 2.
let set_cursor_flush_interval s = cursor_flush_interval := s

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)
  module St = Store.Make (C) (Layout.Inode.Make (C))
  module B = (val C.store : Backend.S)

  let rename_file ~src_key ~dst_key = St.copy_manifest ~src_key ~dst_key
  let head_manifest_opt ~key = St.head_manifest ~key

  (* The one place an entry key becomes a backend key. Concatenating the prefix
     onto a bare entry key skips the month directory and silently misses. *)
  let journal_key entry_key = C.journal_prefix ^ Ek.relative_path entry_key

  let write_journal_entry_body ?entry_key body =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let+ () = B.put ~key:(journal_key ek) ~data:body () in
    ek

  let write_journal_entry ?entry_key ops =
    write_journal_entry_body ?entry_key (Bigstring.of_string (Journal.encode ops))

  let cursor_state () =
    match Hashtbl.find_opt cursor_states C.cursor_key with
      | Some s -> s
      | None ->
          let s =
            {
              pending = None;
              last_published = 0.;
              timer_armed = false;
              publish_lock = Lwt_mutex.create ();
            }
          in
          Hashtbl.replace cursor_states C.cursor_key s;
          s

  (* Serialized: a timer flush and a drain flush landing together would be two
     concurrent writes to the one object this exists to write less often. The
     clock restarts when the write lands, so the spacing is between writes. *)
  let publish_cursor s entry_key =
    Lwt_mutex.with_lock s.publish_lock (fun () ->
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
      | None -> Lwt.return_unit
      | Some entry_key ->
          Lwt.catch
            (fun () -> publish_cursor s entry_key)
            (fun exn ->
              (* Swallowed: this runs from a timer and from drain, and a dying
                 backend must not take either down. The entry is published
                 either way, and a peer that cannot bridge the gap resyncs. *)
              Log.err "bump_cursor: %s" (Printexc.to_string exn);
              Lwt.return_unit)

  let arm s =
    if not s.timer_armed then begin
      s.timer_armed <- true;
      Lwt.async (fun () ->
          let quiet_for = Unix.gettimeofday () -. s.last_published in
          let* () =
            Lwt_unix.sleep (max 0. (!cursor_flush_interval -. quiet_for))
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
      Lwt.return_unit
    end

  let note_cursor entry_key =
    let s = cursor_state () in
    note s entry_key;
    arm s

  (* How far this client has applied the shared journal. Local, because it says
     what *we* have caught up to, not what was published. *)
  let last_sync_file = Filename.concat C.data_dir ("last-sync-" ^ C.domain_name)

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
    Option.bind body (fun b -> Ek.of_string (String.trim (Bigstring.to_string b)))

  let list_journal_keys ?start_after () =
    let+ all = B.list_prefix ~prefix:C.journal_prefix () in
    List.filter_map
      (fun (e : Backend.file_entry) ->
        (* Entries sit in month directories ({!Ek.relative_path}); [of_string]
           takes the last segment. *)
          match Ek.of_string e.key with
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
    Lwt.catch
      (fun () ->
        let+ d = B.get ~key () in
        Some (Journal.decode (Bigstring.to_string d)))
      (fun _ -> Lwt.return_none)

  let journal_entry_published entry_key =
    let+ head = B.head_opt ~key:(journal_key entry_key) () in
    head <> None
end
