open Lwt.Syntax

exception Cancelled = Backend.Cancelled

type recheck_report = {
  chunks_total : int;
  chunks_repaired : int;
  chunks_unrepairable : int;
  manifest_repaired : bool;
  manifest_bad : bool;
}

let manifest_matches (a : Manifest.t) (b : Manifest.t) =
  a.Manifest.h1 = b.Manifest.h1
  && a.Manifest.h2 = b.Manifest.h2
  && a.Manifest.size = b.Manifest.size

(* Positioned reads rather than lseek+read: chunks of one file are read
   concurrently (see [chunk_buffers] and [max_uploads]) and a shared fd's seek
   position would race. pread has no such state, so one fd serves a whole file
   instead of one per chunk — each open/seek/close is a blocking syscall on Lwt's
   worker pool, thousands of round trips for a multi-GB upload. A short read
   means the file was truncated under us: abort. *)
let read_chunk_into fd offset len buf =
  let rec loop pos =
    if pos >= len then Lwt.return_unit
    else
      let* n =
        Lwt_unix_retry.pread fd buf ~file_offset:(offset + pos) pos (len - pos)
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

  val get_chunk : chunk_key:string -> string Lwt.t

  (** Chunk size for files this client creates; see the .mli. *)
  val chunk_size : unit -> int Lwt.t

  val upload_chunks :
    key:string ->
    name:string ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> [ `Reuse of string | `Data of string ] Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t Lwt.t

  val fetch_manifest : key:string -> unit -> Manifest.t option Lwt.t

  val recheck_from_manifest :
    key:string ->
    local_body:(int -> string option Lwt.t) ->
    Manifest.t ->
    recheck_report Lwt.t
end

module Make_with_layout (C : Conf.S) (L : Layout.S) : S = struct
  (* [St] maps logical keys to backend keys through the layout scheme. *)
  module St = Store.Make (C) (L)
  module Bk = Backends.Make (C)

  let primary = Bk.primary

  (* Chunk-sized buffers shared by every concurrent upload: a fixed set avoids a
     stream of large major-heap allocations under sustained upload traffic, and
     Lwt_pool allocates lazily so nothing is held when idle. A string derived from
     a buffer aliases its backing memory and must not outlive the callback.

     Acquiring here is also the real system-wide bound on concurrent chunk work:
     a chunk read blocks until a slot frees, whatever file it belongs to, so
     [max_chunk_buffers] times the chunk size is what the upload path costs in
     memory however many files [max_uploads] admits. *)
  (* Sized off the configured value, not the resolved one: only an upper bound
     for the common case is needed, and an oversized chunk falls through to a
     one-off allocation below. *)
  let buffer_size = Option.value C.chunk_size ~default:Conf.default_chunk_size

  let chunk_buffers =
    Lwt_pool.create (max 1 C.max_chunk_buffers) (fun () ->
        Lwt.return (Bytes.create buffer_size))

  (* Config, else what the primary backend recommends (an http-proxy answers with
     the serving domain's own, so the setting need not live in two configs), else
     the built-in default. Memoized: the answer is fixed for the process. *)
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
                      let (module Primary : Backend.S) = primary () in
                      let+ n =
                        Primary.default_chunk_size ~prefix:C.domain_prefix ()
                      in
                      Option.value n ~default:Conf.default_chunk_size)
                    (fun _ -> Lwt.return Conf.default_chunk_size)
          in
          resolved_chunk_size := Some p;
          p

  (* From the pool when it fits the domain chunk size, else a one-off allocation
     — only hit re-chunking a file whose manifest used a larger chunk size than
     the domain now configures. *)
  let with_chunk_buffer ~size f =
    if size <= buffer_size then Lwt_pool.use chunk_buffers f
    else f (Bytes.create size)

  (* Chunk keys known present on the primary backend, this session only: a HEAD
     decides, and the result is memoized so a chunk repeated within the session
     skips the round trip. Not pre-populated by listing the chunk prefix — that
     cost scales with the whole historical archive rather than the upload at hand,
     and only pays off for cross-session dedup. *)
  let known_chunks : (string, unit) Hashtbl.t = Hashtbl.create 4096

  (* Sharded, so no single directory holds the whole store on a filesystem
     backend. *)
  let chunk_backend_key chunk_key =
    C.chunk_prefix ^ Chunk_layout.relative_path chunk_key

  let chunk_exists ck =
    let (module Primary : Backend.S) = primary () in
    let+ head = Primary.head_opt ~key:ck () in
    Option.is_some head

  (* [data] is not retained past this call, so a caller may pass a string
     aliasing a pooled buffer. *)
  let put_chunk ~index ~data =
    let size = String.length data in
    let entry =
      Manifest.
        {
          index;
          h1 = Xxhash.hash_hex data 0;
          h2 = Xxhash.hash_hex data 1;
          size;
        }
    in
    Metrics.add_hashed 1;
    let ck_rel = Manifest.chunk_key entry in
    let ck = chunk_backend_key ck_rel in
    let* known =
      if Hashtbl.mem known_chunks ck_rel then Lwt.return_true
      else chunk_exists ck
    in
    let+ () =
      if known then (
        Hashtbl.replace known_chunks ck_rel ();
        Lwt.return_unit)
      else (
        Metrics.add_uploaded size;
        let+ () = Bk.put ~key:ck ~data in
        Hashtbl.replace known_chunks ck_rel ())
    in
    entry

  (* Reads, hashes and uploads chunk [index] unless it is already present. *)
  let upload_chunk fd ~cancel ~file_size ~chunk_size index =
    if !cancel then raise Cancelled;
    let offset = index * chunk_size in
    let size = min chunk_size (file_size - offset) in
    with_chunk_buffer ~size (fun buf ->
        let* () = read_chunk_into fd offset size buf in
        (* Zero-copy for a full chunk; a short last chunk needs its own copy
           since it cannot alias the whole pooled buffer. Either way [data] must
           not outlive the hash and upload: the buffer is reused once
           released. *)
        let data =
          if size = Bytes.length buf then Bytes.unsafe_to_string buf
          else Bytes.sub_string buf 0 size
        in
        put_chunk ~index ~data)

  (* The tail every upload shares. A cancellation landing while the put is in
     flight unpublishes it again, or a ghost object survives under a name that may
     no longer exist locally. Chunks stay: they are content-addressed and the
     successor upload references them. *)
  let publish ~key ~name ~size ~chunk_size ~mtime ~cancel entries =
    if !cancel then raise Cancelled;
    let h1, h2 = Manifest.digest_of_chunks entries in
    let state =
      Manifest.make ~name ~h1 ~h2 ~size ~chunk_size ~chunks:entries ~mtime
    in
    let* () = if C.versioning then St.save_version ~key else Lwt.return_unit in
    Log.info "upload %s: publishing manifest, size=%Ld" key size;
    let* () = St.put_manifest ~key ~data:(Manifest.to_string state) in
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
          (* Safe to launch every chunk's task up front: each blocks on the
             [chunk_buffers] pool until a slot frees, so concurrency stays capped
             at [max_chunk_buffers] however many chunks contend. *)
          Lwt_list.map_p
            (upload_chunk fd ~cancel ~file_size ~chunk_size)
            (List.init num_chunks Fun.id))
        (fun () -> Lwt_unix_retry.close fd)
    in
    publish ~key ~name:(Filename.basename key) ~size:(Int64.of_int file_size)
      ~chunk_size ~mtime ~cancel entries

  (* [source index] is either the key of a chunk to keep as-is (never read or
     sent) or the chunk's bytes; knowing nothing about where those live keeps
     staging out of this module. An empty file still gets one empty chunk, so
     every manifest has at least one. *)
  let upload_chunks ~key ~name ~size ~chunk_size ~mtime
      ~(source : int -> [ `Reuse of string | `Data of string ] Lwt.t)
      ?(cancel = ref false) () =
    let n = max 1 (Manifest.num_chunks_for size chunk_size) in
    let one index =
      if !cancel then raise Cancelled;
      let* src = source index in
      match src with
        | `Reuse chunk_key ->
            Lwt.return
              (Manifest.entry_of_key ~index
                 ~size:(Manifest.chunk_len ~size ~chunk_size index)
                 chunk_key)
        | `Data data -> put_chunk ~index ~data
    in
    let* entries = Lwt_list.map_p one (List.init n Fun.id) in
    publish ~key ~name ~size ~chunk_size ~mtime ~cancel entries

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

  (* Chunk keys are content-addressed, so a size mismatch means the remote object
     is corrupt. *)
  let chunk_remote_ok ~chunk_key ~size =
    let (module Primary : Backend.S) = primary () in
    let+ head = Primary.head_opt ~key:(chunk_backend_key chunk_key) () in
    match head with Some h -> h.Backend.size = size | None -> false

  (* Republishes [expected] when the remote manifest is missing, dirty or
     differs. [true] when a repair was made. *)
  let recheck_manifest ~key (expected : Manifest.t) =
    let* remote = fetch_manifest ~key () in
    let ok =
      match remote with Some r -> manifest_matches r expected | _ -> false
    in
    if ok then Lwt.return_false
    else (
      Log.info "recheck: republishing manifest %s" key;
      let+ () = St.put_manifest ~key ~data:(Manifest.to_string expected) in
      true)

  (* Concurrent chunk checks during a manifest-driven recheck.

     One bound for the whole check rather than one for the HEAD inside it: a
     chunk the backend is missing goes on to read the local body and re-upload
     it, and those cost what the HEAD does not. Bounding only the HEAD leaves
     the rest to scale with the file.

     Static, like every bound here. A recheck's width is the file's chunk count,
     and a per-call budget would limit one recheck while saying nothing about
     how many run at once — which is no bound on the store underneath. *)
  let recheck_chunks = Lwt_bounded.create ~max:C.max_chunk_buffers ()

  (* Recheck a file from its manifest: every chunk it names must exist remotely
     with the right size, and a missing or wrong remote manifest is republished
     from the sidecar as long as they all do. Local bytes play no part — verifying
     those is {!Chunk_cache.verify_group}'s job. *)
  let recheck_from_manifest ~key ~local_body (m : Manifest.t) =
    (* A chunk missing or corrupt on the backend can still be restored from the
       local chunk store: content addressing means a body found under that key is
       the right bytes by construction. *)
    let table = m.Manifest.chunks in
    let check index =
      let chunk_key = Chunk_table.key table index in
      let* ok =
        chunk_remote_ok ~chunk_key ~size:(Chunk_table.len table index)
      in
      if ok then Lwt.return `Ok
      else
        let* body = local_body index in
        match body with
          | None -> Lwt.return `Missing
          | Some data ->
              Log.info "recheck: re-uploading chunk %s" chunk_key;
              let+ () = Bk.put ~key:(chunk_backend_key chunk_key) ~data in
              `Repaired
    in
    (* One check per chunk of the file, so the width is the file's size. *)
    let* results =
      Lwt_bounded.map_with recheck_chunks check
        (List.init (Chunk_table.count table) Fun.id)
    in
    let count what = List.length (List.filter (fun r -> r = what) results) in
    let chunks_unrepairable = count `Missing in
    let+ manifest_repaired, manifest_bad =
      if chunks_unrepairable > 0 then
        let* remote = fetch_manifest ~key () in
        let ok =
          match remote with Some r -> manifest_matches r m | _ -> false
        in
        Lwt.return (false, not ok)
      else
        let+ repaired = recheck_manifest ~key m in
        (repaired, false)
    in
    {
      chunks_total = Chunk_table.count table;
      chunks_repaired = count `Repaired;
      chunks_unrepairable;
      manifest_repaired;
      manifest_bad;
    }

  (* Bounds concurrent chunk GETs across all downloads, mirroring how
     [chunk_buffers] bounds upload work: every chunk of every file contends
     for the same [max_downloads] slots, so launching all of a file's chunk
     tasks up front cannot exceed the global ceiling. *)
  let chunk_download_pool = Lwt_bounded.create ~max:C.max_downloads ()

  (* Fetch one chunk body by content key. The pool bounds concurrent GETs the
     same way for a demand-paged read as for a whole-file download. *)
  let get_chunk ~chunk_key =
    Lwt_bounded.use chunk_download_pool (fun () ->
        let (module Primary : Backend.S) = primary () in
        let+ data = Primary.get ~key:(chunk_backend_key chunk_key) () in
        Metrics.add_downloaded (String.length data);
        data)
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf.S) = Make_with_layout (C) (Layout.Inode.Make (C))
