type entry = { chunk_key : string; store : string }

type report = {
  entries : entry list;
  unverified : string list;
  unreachable : (string * string) list;
}

(* Long enough that a file's worth of chunks costs one listing, short enough that
   a daemon left running picks up what another client — or a bucket's own
   verifier — filed while it was working. *)
let ttl = 5.

module type S = sig
  type 'a io
  type store

    val list : unit -> report io

    val member_entries :
    ?max_keys:int ->
    store Backend.member ->
    [ `Unverified | `Entries of entry list ] io

    val detail : entry -> Corruption_marker.t option io

  
    val is_marked : string -> bool io

    val forget : string -> unit

    val invalidate : unit -> unit
end

module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type store := (module C.Store)
end

module Over (Io : Io.S) = struct
  open Io_syntax.Make (Io)

  (* [loaded] is what the listing settled on, kept beside the listing itself so
     that {!Make.forget} can drop a key without waiting: a caller clearing a
     marker it has just rewritten is in the middle of an upload. *)
  type memo = {
    mutable keys : (string, unit) Hashtbl.t Io.t option;
    mutable loaded : (string, unit) Hashtbl.t option;
    mutable at : float;
  }

  (* Keyed by the chunk prefix and not held in the functor: {!Remote.Make} is
     applied in half a dozen places — the uploader, diagnostics, export, import,
     the share server — and per-application state would have each of them
     listing separately and believing something different about the same store. *)
  let memos : (string, memo) Hashtbl.t = Hashtbl.create 4

  let memo_for prefix =
    match Hashtbl.find_opt memos prefix with
      | Some m -> m
      | None ->
          let m = { keys = None; loaded = None; at = 0. } in
          Hashtbl.replace memos prefix m;
          m

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module L = Chunk_layout.Make (C)

    let prefix = L.corrupted_prefix
    let key = L.corrupted_key

    (* Unbounded for {!list}, which is feeding a repair rather than a report. *)
    let entries_on ?max_keys ~store (module B : C.Store) =
      let+ found = B.list_prefix ?max_keys ~prefix () in
      List.filter_map
        (fun (e : Backend.file_entry) ->
          (* Shape, not prefix: a filesystem store lists back the shard directory
             it made to hold a marker, and counting that would report a corrupt
             chunk whose name is not even there. *)
          if Chunk_layout.is_marker_key e.Backend.key then
            Some
              {
                chunk_key = Chunk_layout.chunk_key_of_marker e.Backend.key;
                store;
              }
          else None)
        found

    let member_entries ?max_keys (m : (module C.Store) Backend.member) =
      let (module B : C.Store) = m.Backend.backend in
      let* caps = B.capabilities ~prefix:C.domain_prefix () in
      if not caps.Backend.verified then Io.return `Unverified
      else
        let+ entries =
          entries_on ?max_keys ~store:m.Backend.name m.Backend.backend
        in
        `Entries entries

    let list () =
      let+ per_member =
        map_s
          (fun (m : (module C.Store) Backend.member) ->
            Io.catch
              (fun () ->
                let+ found = member_entries m in
                match found with
                  | `Unverified -> `Unverified m.Backend.name
                  | `Entries es -> `Entries es)
              (fun exn ->
                Io.return (`Unreachable (m.Backend.name, Retry.reason exn))))
          C.members
      in
      List.fold_left
        (fun acc -> function
          | `Entries es -> { acc with entries = acc.entries @ es }
          | `Unverified name ->
              { acc with unverified = acc.unverified @ [name] }
          | `Unreachable (name, why) ->
              { acc with unreachable = acc.unreachable @ [(name, why)] })
        { entries = []; unverified = []; unreachable = [] }
        per_member

    (* From the member the entry names, for the reason {!list} asks each of them
       separately: a read through the composite would come back from whichever
       store answered first, which need not be the one that wrote the marker. *)
    let detail e =
      match
        List.find_opt
          (fun (m : (module C.Store) Backend.member) ->
            m.Backend.name = e.store)
          C.members
      with
        | None -> Io.return None
        | Some m ->
            let (module B : C.Store) = m.Backend.backend in
            Io.catch
              (fun () ->
                let+ body = B.get_opt ~key:(key e.chunk_key) () in
                Option.map
                  (fun body ->
                    Corruption_marker.of_string (Bigstring.to_string body))
                  body)
              (fun _ -> Io.return None)

    let memo () = memo_for C.chunk_prefix

    let load () =
      let+ report = list () in
      let t = Hashtbl.create 16 in
      List.iter (fun e -> Hashtbl.replace t e.chunk_key ()) report.entries;
      t

    (* The timestamp is stamped before the listing is awaited, so the chunks of
       one upload share a single request rather than each starting its own.

       A listing that fails reads as "nothing marked" — see the .mli — and the
       chunk it would have held back is caught by the next pass. *)
    let marked () =
      let m = memo () in
      let now = Unix.gettimeofday () in
      match m.keys with
        | Some p when now -. m.at < ttl -> p
        | _ ->
            let p =
              let+ t =
                Io.catch
                  (fun () -> load ())
                  (fun _ -> Io.return (Hashtbl.create 1))
              in
              m.loaded <- Some t;
              t
            in
            m.at <- now;
            m.keys <- Some p;
            m.loaded <- None;
            p

    let is_marked chunk_key =
      let+ t = marked () in
      Hashtbl.mem t chunk_key

    let forget chunk_key =
      match (memo ()).loaded with
        | None -> ()
        | Some t -> Hashtbl.remove t chunk_key

    let invalidate () =
      let m = memo () in
      m.keys <- None;
      m.loaded <- None;
      m.at <- 0.
  end
end
