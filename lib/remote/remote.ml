open Lwt.Syntax

exception Cancelled = Retry.Cancelled

(* Raised when the file an upload is reading moves under it, so its chunks would
   describe bytes the file never held together. *)
exception Source_changed of string

let () =
  Printexc.register_printer (function
    | Source_changed p -> Some (p ^ ": changed while it was being read")
    | _ -> None)

module type S = sig
  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t Lwt.t

  val get_chunk : chunk_key:string -> Bigstring.t Lwt.t

  (** Chunk size for files this client creates; see the .mli. *)
  val chunk_size : unit -> int Lwt.t

  val known_chunk_count : unit -> int

  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit Lwt.t Chunk_source.t Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t Lwt.t

  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option Lwt.t

  val fetch_manifest_state :
    key:Logical_key.t ->
    unit ->
    [ `Found of Manifest.t | `Absent | `Unresolved | `Unreadable ] Lwt.t
end

(* Settable so a test can reach the cap without uploading a terabyte. *)
let max_known = ref 100_000
let set_max_known n = max_known := n

(* Keyed by the chunk prefix and not held in the functor: {!Make} is applied
   once per domain and per role -- the uploader, diagnostics, export, import, the
   share server -- and a per-application pool bounds each of those separately
   while all of them queue on one device and one memory budget. A proxy serving
   shares beside an engine held two of each and admitted twice what either said.

   Same reasoning as {!Corruption}'s memo, which is keyed the same way. *)
type pools = { chunk_slots : Io_lwt.Bounded.t; downloads : Io_lwt.Bounded.t }

let pools : (string, pools) Hashtbl.t = Hashtbl.create 4

let pools_for ~prefix ~max_chunk_buffers ~max_downloads =
  match Hashtbl.find_opt pools prefix with
    | Some p -> p
    | None ->
        (* Acquiring a slot is the real system-wide bound on concurrent chunk
           work: a chunk read blocks until one frees, whatever file it belongs
           to, so [max_chunk_buffers] times the chunk size is what the upload
           path costs in memory however many files [max_uploads] admits.

           Bound in sequence rather than in a record literal: {!Lwt_bounded}
           reports pools in creation order, and a literal's field order is not
           its evaluation order. *)
        let chunk_slots =
          Io_lwt.Bounded.create ~name:"chunk buffers"
            ~max:(max 1 max_chunk_buffers) ()
        in
        let downloads =
          Io_lwt.Bounded.create ~name:"downloads" ~max:max_downloads ()
        in
        let p = { chunk_slots; downloads } in
        Hashtbl.replace pools prefix p;
        p

module Make_with_layout (C : Conf_lwt.S) (L : Layout.S) : S = struct
  (* [St] maps logical keys to backend keys through the layout scheme. *)
  module St = Store.Make (C) (L)
  module Hs = History.Make (C) (L)
  module B = (val C.store : C.Store)

  (* Chunk writes go where they always went; only presence checks and reads have
     to know that a collection may be in progress ({!Collection}). *)
  module Collection = Collection.Make (C)
  module L = Chunk_layout.Make (C)
  module Corrupt = Corruption.Make (C)

  let pools =
    pools_for ~prefix:C.chunk_prefix ~max_chunk_buffers:C.max_chunk_buffers
      ~max_downloads:C.max_downloads

  let chunk_slots = pools.chunk_slots

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
  (* Workers as wide as the buffer pool, each taking the next index: a promise
     apiece is a fan-out the file's size chooses, and a terabyte's worth of them
     is allocated before the first chunk is read and outlives every buffer they
     queue for.

     The slot is taken inside [f], not here, so nothing holds one while asking
     for one. *)
  let each_chunk ~count f =
    let next = ref 0 in
    Io_lwt.Bounded.each ~width:(Io_lwt.Bounded.width chunk_slots) (fun () ->
        if !next >= count then None
        else (
          let index = !next in
          incr next;
          Some (fun () -> f index)))

  module Chunks_store = Chunk_store.Make (struct
    let put = B.put
    let backend_key = L.key
    let fetch_body = Collection.get
    let corrupt = Corrupt.is_marked
    let cleared = Corrupt.forget
    let slots = chunk_slots
    let downloads = pools.downloads
    let max_known () = !max_known

    let present key =
      let+ head = Collection.head key in
      Option.is_some head
  end)

  let known_chunk_count = Chunks_store.known_count

  (* Mapped rather than read, so the pages reach the store without being copied
     into a buffer first, and mapped from a snapshot, so what the user writes
     next reaches neither these pages nor the ones still to come. *)
  let upload_chunk fd ~cancel ~on_progress ~file_size ~chunk_size ~table index =
    if !cancel then raise Cancelled;
    let offset = Chunks.offset_of ~chunk_size index in
    let len =
      Chunks.length_of ~size:(Int64.of_int file_size) ~chunk_size index
    in
    let+ ck_rel, sent =
      Chunks_store.store
        (Chunk_source.Mapped
           (fun () ->
             try Bigstring.map_fd fd ~offset ~len
             with Unix.Unix_error _ -> raise Cancelled))
    in
    Manifest.set table index ck_rel;
    (* A deduplicated chunk is as done as a written one and cost no transfer,
       which is why the two are told apart rather than summed. *)
    on_progress ~bytes:len ~sent

  (* A cancellation landing while the put is in flight unpublishes it again, or
     a ghost object survives under a name that may no longer exist locally.

     Chunks stay: they are content-addressed and the successor upload references
     them. *)
  (* The key being published under is what names this file. *)
  let chunk_table ~key ~size ~chunk_size ~mtime ~count =
    Manifest.builder ~name:(Logical_key.leaf key) ~size ~chunk_size ~mtime
      ~symlink:None ~count

  let publish ~key ~size ~chunk_size ~mtime ~cancel table =
    if !cancel then raise Cancelled;
    let count = Manifest.builder_count table in
    let chunk_key = Manifest.get table in
    let h1, h2 =
      Manifest.digest_of_keys ~count ~key:chunk_key
        ~len:(Chunks.length_of ~size ~chunk_size)
    in
    let body = Manifest.seal table ~h1 ~h2 in
    let state = Manifest.of_chunk body in
    let* () = if C.versioning then Hs.save_version ~key else Lwt.return_unit in
    Log.info "upload %s: publishing manifest, size=%Ld"
      (Logical_key.to_string key)
      size;
    (* Before the manifest is visible, never after: a chunk this upload did not
       write — deduplicated, or already known to this session — may hold a name
       only in a space a collection is about to discard. *)
    let* () = Collection.promote_all ~count chunk_key in
    let* () = St.put_manifest ~key ~data:body in
    if !cancel then
      let* () =
        Lwt.catch
          (fun () -> St.delete_manifest ~key)
          (fun exn ->
            Log.err "upload %s: cancelled-manifest cleanup failed: %s"
              (Logical_key.to_string key)
              (Printexc.to_string exn);
            Lwt.return_unit)
      in
      raise Cancelled
    else Lwt.return state

  (* For a file handed over whole: import, and the FileProvider's re-import.

     Sized from the descriptor the chunks are mapped through, so the length the
     chunking is laid out for and the bytes that reach the store come from one
     file however the name is reused meanwhile.

     [fd] is the source itself, kept alongside the snapshot only to be stat'd
     for whether the file moved while this ran. *)
  let upload ~key ~src_path ~mtime ~chunk_size ?(cancel = ref false)
      ?(on_progress = fun ~bytes:_ ~sent:_ -> ()) () =
    let* fd = Io_lwt.Retry.openfile src_path [Unix.O_RDONLY] 0 in
    let* table, file_size =
      Lwt.finalize
        (fun () ->
          let* before = Io_lwt.Retry.LargeFile.fstat fd in
          (* Frozen here, so a source truncated mid-upload is a manifest never
             published rather than a SIGBUS on a page past its new end. *)
          let snapshot = Bigstring.open_snapshot src_path in
          Lwt.finalize
            (fun () ->
              let file_size =
                Int64.to_int
                  (Unix.LargeFile.fstat snapshot).Unix.LargeFile.st_size
              in
              Log.debug "upload %s: file_size=%d"
                (Logical_key.to_string key)
                file_size;
              (* An empty file is one chunk of no bytes, where covering zero
                 bytes takes none. *)
              let num_chunks =
                max 1 (Chunks.count ~size:(Int64.of_int file_size) ~chunk_size)
              in
              let table =
                chunk_table ~key ~size:(Int64.of_int file_size) ~chunk_size
                  ~mtime ~count:num_chunks
              in
              let* () =
                each_chunk ~count:num_chunks
                  (upload_chunk snapshot ~cancel ~on_progress ~file_size
                     ~chunk_size ~table)
              in
              (* The snapshot makes the chunks agree with each other; this is
                 what says they still describe the file the user has. *)
              let+ after = Io_lwt.Retry.LargeFile.fstat fd in
              if
                after.Unix.LargeFile.st_size <> before.Unix.LargeFile.st_size
                || after.Unix.LargeFile.st_mtime
                   <> before.Unix.LargeFile.st_mtime
              then raise (Source_changed src_path);
              (table, file_size))
            (fun () ->
              Unix.close snapshot;
              Lwt.return_unit))
        (fun () -> Io_lwt.Retry.close fd)
    in
    publish ~key ~size:(Int64.of_int file_size) ~chunk_size ~mtime ~cancel table

  (* Fillers write into a pooled buffer, which is what holds this path to
     [max_chunk_buffers] chunks however wide the fan-out below runs.

     Deciding which case a chunk is must stay free of I/O, or every chunk's bytes
     land before anything queues for a buffer. *)
  let upload_chunks ~key ~size ~chunk_size ~mtime
      ~(source : int -> unit Lwt.t Chunk_source.t Lwt.t) ?(cancel = ref false)
      () =
    let n = max 1 (Chunks.count ~size ~chunk_size) in
    let table = chunk_table ~key ~size ~chunk_size ~mtime ~count:n in
    let one index =
      if !cancel then raise Cancelled;
      let* src = source index in
      let+ ck_rel, (_ : bool) = Chunks_store.store src in
      Manifest.set table index ck_rel
    in
    let* () = each_chunk ~count:n one in
    publish ~key ~size ~chunk_size ~mtime ~cancel table

  let fetch_manifest_state ~key () =
    let+ state = St.get_manifest_state ~key in
    match state with
      | `Unresolved -> `Unresolved
      | `Absent -> `Absent
      | `Body body -> (
          match Manifest.of_string body with
            | m -> `Found m
            (* Read again rather than remembered: a body that will not parse is
               a write in flight, which is a moment rather than an answer. *)
            | exception _ -> `Unreadable)

  let fetch_manifest ~key () =
    let+ state = fetch_manifest_state ~key () in
    match state with
      | `Found m -> Some m
      (* Absent, unresolved and unparseable all read as no metadata, so stat
         reports ENOENT rather than garbage. *)
      | `Absent | `Unresolved | `Unreadable -> None

  let get_chunk ~chunk_key = Chunks_store.fetch chunk_key
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf_lwt.S) = Make_with_layout (C) (Layout.Inode.Make (C))
