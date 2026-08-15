open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Positioned reads rather than lseek+read: chunks of one file are read
   concurrently and a shared fd's seek position would race, so one fd serves a
   whole file instead of one per chunk.

   A short read means the file was truncated under us: abort. *)
let read_chunk_into fd offset len buf =
  let rec loop pos =
    if pos >= len then Lwt.return_unit
    else
      let* n =
        Local_io.pread fd buf ~file_offset:(offset + pos) pos (len - pos)
      in
      if n = 0 then raise Cancelled else loop (pos + n)
  in
  loop 0

module type S = sig
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t Lwt.t

  val get_chunk : chunk_key:string -> Chunk.t Lwt.t

  (** Chunk size for files this client creates; see the .mli. *)
  val chunk_size : unit -> int Lwt.t

  val upload_chunks :
    key:string ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:
      (int ->
      [ `Reuse of string | `Fill of Local_io.buffer -> unit Lwt.t ] Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t Lwt.t

  val fetch_manifest : key:string -> unit -> Manifest.t option Lwt.t
end

module Make_with_layout (C : Conf.S) (L : Layout.S) : S = struct
  (* [St] maps logical keys to backend keys through the layout scheme. *)
  module St = Store.Make (C) (L)
  module B = (val C.store : Backend.S)

  (* Chunk writes go where they always went; only presence checks and reads have
     to know that a collection may be in progress ({!Chunk_space}). *)
  module Space = Chunk_space.Make (C)
  module Corrupt = Corruption.Make (C)

  (* Acquiring a slot is the real system-wide bound on concurrent chunk work: a
     chunk read blocks until one frees, whatever file it belongs to, so
     [max_chunk_buffers] times the chunk size is what the upload path costs in
     memory however many files [max_uploads] admits. *)
  let chunk_slots = Lwt_bounded.create ~max:(max 1 C.max_chunk_buffers) ()

  (* Config, else what the domain's stores recommend (an http-proxy answers with
     the serving domain's own, so the setting need not live in two configs),
     else the built-in default. *)
  let resolved_chunk_size = ref None

  let chunk_size () =
    match !resolved_chunk_size with
      | Some p -> p
      | None ->
          let p =
            match C.chunk_size with
              | Some n -> Lwt.return n
              | None ->
                  Lwt.catch
                    (fun () ->
                      let+ caps = B.capabilities ~prefix:C.domain_prefix () in
                      Option.value caps.Backend.chunk_size
                        ~default:Conf.default_chunk_size)
                    (fun _ -> Lwt.return Conf.default_chunk_size)
          in
          resolved_chunk_size := Some p;
          p

  (* Bytes of its own per chunk, held for as long as anything refers to them: a
     store is free to keep sending after the put that handed them over returns.

     A chunk larger than the configured size — only reachable re-chunking a file
     whose manifest used a larger one — takes a single slot regardless, and so
     costs more than a slot is reckoned to. *)
  let with_chunk_buffer ~size f =
    Lwt_bounded.use chunk_slots (fun () -> f (Chunk.create size))

  (* Chunk keys known present on the domain's stores, this session only. Not
     pre-populated by listing the chunk prefix: that cost scales with the whole
     historical archive rather than the upload at hand. *)
  let known_chunks : (string, unit) Hashtbl.t = Hashtbl.create 4096

  (* Where a chunk is written; where it can be *read* is
     {!Chunk_space.read_key}'s business, a collection in progress being the one
     thing that makes the two differ. *)
  let chunk_backend_key = Space.key

  let chunk_exists ck_rel =
    let+ head = Space.head ck_rel in
    Option.is_some head

  (* [data] must own its bytes: a store is free to keep sending after this
     returns, and the key is the hash of what was passed, not of what lands. *)
  let put_chunk ~index ~data =
    let size = Chunk.length data in
    let entry = Manifest.chunk_entry_of_body ~index data in
    Metrics.add_hashed 1;
    let ck_rel = Manifest.chunk_key entry in
    let ck = chunk_backend_key ck_rel in
    let* known =
      (* Ahead of the session memo rather than behind it. A chunk this session
         uploaded is already in [known_chunks], and a marker says exactly that
         what it uploaded is not what landed; asking the store instead would not
         help either, a corrupt chunk being the right size and so present.

         This is what closes the loop. Skipping the write would leave the marker
         standing with nothing to clear it, and — because dedup is what makes a
         chunk shared — would hand the bad bytes to every later file that
         contains it. *)
      let* marked = Corrupt.is_marked ck_rel in
      if marked then Lwt.return_false
      else if Hashtbl.mem known_chunks ck_rel then Lwt.return_true
      else chunk_exists ck_rel
    in
    let+ () =
      if known then (
        Hashtbl.replace known_chunks ck_rel ();
        Lwt.return_unit)
      else (
        Metrics.add_uploaded size;
        let+ () = B.put ~key:ck ~data () in
        (* The write is what clears the marker — the store re-verified the object
           as it took it — so stop holding this key against the rest of the
           session. *)
        Corrupt.forget ck_rel;
        Hashtbl.replace known_chunks ck_rel ())
    in
    entry

  let upload_chunk fd ~cancel ~file_size ~chunk_size index =
    if !cancel then raise Cancelled;
    let offset = index * chunk_size in
    let size = min chunk_size (file_size - offset) in
    with_chunk_buffer ~size (fun buf ->
        let* () = read_chunk_into fd offset size buf in
        put_chunk ~index ~data:(Chunk.of_buffer buf))

  (* A cancellation landing while the put is in flight unpublishes it again, or
     a ghost object survives under a name that may no longer exist locally.

     Chunks stay: they are content-addressed and the successor upload references
     them. *)
  let publish ~key ~size ~chunk_size ~mtime ~cancel entries =
    if !cancel then raise Cancelled;
    let h1, h2 = Manifest.digest_of_chunks entries in
    (* The key being published under is what names this file. *)
    let name = Key.leaf ~domain_prefix:C.domain_prefix key in
    let state =
      Manifest.make ~name ~h1 ~h2 ~size ~chunk_size ~chunks:entries ~mtime
    in
    let* () = if C.versioning then St.save_version ~key else Lwt.return_unit in
    Log.info "upload %s: publishing manifest, size=%Ld" key size;
    (* Before the manifest is visible, never after: a chunk this upload did not
       write — deduplicated, or already known to this session — may hold a name
       only in a space a collection is about to discard. *)
    let* () = Space.promote_all (List.map Manifest.chunk_key entries) in
    let* () = St.put_manifest ~key ~data:(Manifest.to_string ~name state) in
    if !cancel then
      let* () =
        Lwt.catch
          (fun () -> St.delete_manifest ~key)
          (fun exn ->
            Log.err "upload %s: cancelled-manifest cleanup failed: %s" key
              (Printexc.to_string exn);
            Lwt.return_unit)
      in
      raise Cancelled
    else Lwt.return state

  (* For a file handed over whole: import, and the FileProvider's re-import. *)
  let upload ~key ~src_path ~mtime ~chunk_size ?(cancel = ref false) () =
    let* st = Lwt_unix_retry.stat src_path in
    let file_size = st.Unix.st_size in
    Log.debug "upload %s: file_size=%d" key file_size;
    let num_chunks =
      if file_size = 0 then 1 else (file_size + chunk_size - 1) / chunk_size
    in
    let* fd = Lwt_unix_retry.openfile src_path [Unix.O_RDONLY] 0 in
    let* entries =
      Lwt.finalize
        (fun () ->
          (* Safe to launch every chunk's task up front: each blocks on
             [chunk_slots] until one frees, so concurrency stays capped at
             [max_chunk_buffers] however many chunks contend. *)
          Lwt_list.map_p
            (upload_chunk fd ~cancel ~file_size ~chunk_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix_retry.close fd)
    in
    publish ~key ~size:(Int64.of_int file_size) ~chunk_size ~mtime ~cancel
      entries

  (* Fillers write into a pooled buffer, which is what holds this path to
     [max_chunk_buffers] chunks however wide the fan-out below runs.

     Deciding which case a chunk is must stay free of I/O, or every chunk's bytes
     land before anything queues for a buffer. *)
  let upload_chunks ~key ~size ~chunk_size ~mtime
      ~(source :
         int ->
         [ `Reuse of string | `Fill of Local_io.buffer -> unit Lwt.t ] Lwt.t)
      ?(cancel = ref false) () =
    let n = max 1 (Manifest.num_chunks_for size chunk_size) in
    let one index =
      if !cancel then raise Cancelled;
      let len = Manifest.chunk_len ~size ~chunk_size index in
      let* src = source index in
      match src with
        | `Reuse chunk_key ->
            Lwt.return (Manifest.entry_of_key ~index ~size:len chunk_key)
        | `Fill fill ->
            with_chunk_buffer ~size:len (fun buf ->
                let* () = fill buf in
                put_chunk ~index ~data:(Chunk.of_buffer buf))
    in
    let* entries = Lwt_list.map_p one (List.init n Fun.id) in
    publish ~key ~size ~chunk_size ~mtime ~cancel entries

  let fetch_manifest ~key () =
    let+ body = St.get_manifest_opt ~key in
    match body with
      | None -> None
      | Some body -> (
          (* An unparseable manifest is treated as absent, so stat reports ENOENT
             rather than garbage metadata. *)
            match Manifest.of_string body with
            | m -> Some m
            | exception _ -> None)

  let chunk_download_pool = Lwt_bounded.create ~max:C.max_downloads ()

  let get_chunk ~chunk_key =
    Lwt_bounded.use chunk_download_pool (fun () ->
        let+ data = Space.get chunk_key in
        Metrics.add_downloaded (Chunk.length data);
        data)
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf.S) = Make_with_layout (C) (Layout.Inode.Make (C))
