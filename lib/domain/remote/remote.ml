exception Cancelled = Retry.Cancelled

(* Raised when the file an upload is reading moves under it, so its chunks would
   describe bytes the file never held together. *)
exception Source_changed of string

let () =
  Printexc.register_printer (function
    | Source_changed p -> Some (p ^ ": changed while it was being read")
    | _ -> None)

module type S = sig
  type 'a io

  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t io

  val get_chunk : chunk_key:string -> Bigstring.t io

  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io

  (** Chunk size for files this client creates; see the .mli. *)
  val chunk_size : unit -> int io

  val known_chunk_count : unit -> int

  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit io Chunk_source.t io) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t io

  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
end

(* Settable so a test can reach the cap without uploading a terabyte. *)
let max_known = ref 100_000
let set_max_known n = max_known := n

(** The bound on what runs at once: chunk buffers and reads in flight. *)
module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val width : t -> int
  val each : width:int -> (unit -> (unit -> unit io) option) -> unit io
end

(** Opening the source file, and asking whether it moved while it was read. *)
module type SYSCALLS = sig
  type 'a io
  type fd

  val openfile : string -> Unix.open_flag list -> int -> fd io
  val close : fd -> unit io

  module LargeFile : sig
    val fstat : fd -> Unix.LargeFile.stats io
  end
end

(** The key scheme a caller holding real paths wants. *)
module type INODE_LAYOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) :
    Layout.S with type 'a io := 'a io
end

(** Publishing a manifest and taking it back, which is all this does with one.
*)
module type MANIFESTS = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : Layout.S with type 'a io := 'a io) : sig
    val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

    val get_manifest_state :
      key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

    val delete_manifest : key:Logical_key.t -> unit io
  end
end

(** Snapshotting what a write is about to replace. *)
module type VERSIONS = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : Layout.S with type 'a io := 'a io) : sig
    val save_version : key:Logical_key.t -> unit io
  end
end

(** Where a chunk is while a collection is under way, and what keeps one alive
    across it. *)
module type COLLECTION = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val get : string -> Bigstring.t io
    val get_range : string -> offset:int -> length:int -> Bigstring.t io
    val head : string -> Backend.file_entry option io
    val promote_all : count:int -> (int -> string) -> unit io
  end
end

(** Which chunks a store filed as not holding what their names say. *)
module type CORRUPTION = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val is_marked : string -> bool io
    val forget : string -> unit
  end
end

module Over
    (Io : Io.S)
    (Pools : POOLS with type 'a io := 'a Io.t)
    (Syscalls : SYSCALLS with type 'a io := 'a Io.t)
    (Inode_layout : INODE_LAYOUT with type 'a io := 'a Io.t)
    (Manifests : MANIFESTS with type 'a io := 'a Io.t)
    (Versions : VERSIONS with type 'a io := 'a Io.t)
    (Collection : COLLECTION with type 'a io := 'a Io.t)
    (Corruption : CORRUPTION with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  module Bodies = Chunk_store.Over (Io) (Pools)

  (* Keyed by the chunk prefix and not held in the functor: {!Make} is applied
     once per domain and per role -- the uploader, diagnostics, export, import, the
     share server -- and a per-application pool bounds each of those separately
     while all of them queue on one device and one memory budget. A proxy serving
     shares beside an engine held two of each and admitted twice what either said.

     Same reasoning as {!Corruption}'s memo, which is keyed the same way. *)
  type pools = { chunk_slots : Pools.t; downloads : Pools.t }

  let pools : (string, pools) Hashtbl.t = Hashtbl.create 4

  let pools_for ~prefix ~max_chunk_buffers ~max_downloads =
    match Hashtbl.find_opt pools prefix with
      | Some p -> p
      | None ->
          (* Acquiring a slot is the real system-wide bound on concurrent chunk
             work: a chunk read blocks until one frees, whatever file it belongs
             to, so [max_chunk_buffers] times the chunk size is what the upload
             path costs in memory however many files [max_uploads] admits.

             Bound in sequence rather than in a record literal: the pool
             reports pools in creation order, and a literal's field order is not
             its evaluation order. *)
          let chunk_slots =
            Pools.create ~name:"chunk buffers" ~max:(max 1 max_chunk_buffers) ()
          in
          let downloads =
            Pools.create ~name:"downloads" ~max:max_downloads ()
          in
          let p = { chunk_slots; downloads } in
          Hashtbl.replace pools prefix p;
          p

  module Make_with_layout
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t =
  struct
    (* [St] maps logical keys to backend keys through the layout scheme. *)
    module St = Manifests.Make (C) (L)
    module Hs = Versions.Make (C) (L)
    module B = (val C.store : C.Store)

    (* Chunk writes go where they always went; only presence checks and reads have
       to know that a collection may be in progress ({!Collection}). *)
    module Space = Collection.Make (C)
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
                | Some n -> Io.return n
                | None ->
                    Io.catch
                      (fun () ->
                        let+ caps = B.capabilities ~prefix:C.domain_prefix () in
                        Option.value caps.Backend.chunk_size
                          ~default:Conf.default_chunk_size)
                      (fun _ -> Io.return Conf.default_chunk_size)
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
      Pools.each ~width:(Pools.width chunk_slots) (fun () ->
          if !next >= count then None
          else (
            let index = !next in
            incr next;
            Some (fun () -> f index)))

    module Chunks_store = Bodies.Make (struct
      let put = B.put
      let backend_key = L.key
      let fetch_body = Space.get
      let fetch_body_range = Space.get_range
      let corrupt = Corrupt.is_marked
      let cleared = Corrupt.forget
      let slots = chunk_slots
      let downloads = pools.downloads
      let max_known () = !max_known

      let present key =
        let+ head = Space.head key in
        Option.is_some head
    end)

    let known_chunk_count = Chunks_store.known_count

    (* Mapped rather than read, so the pages reach the store without being copied
       into a buffer first, and mapped from a snapshot, so what the user writes
       next reaches neither these pages nor the ones still to come. *)
    let upload_chunk fd ~cancel ~on_progress ~file_size ~chunk_size ~table index
        =
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
      let* () = if C.versioning then Hs.save_version ~key else Io.return () in
      Log.info "upload %s: publishing manifest, size=%Ld"
        (Logical_key.to_string key)
        size;
      (* Before the manifest is visible, never after: a chunk this upload did not
         write — deduplicated, or already known to this session — may hold a name
         only in a space a collection is about to discard. *)
      let* () = Space.promote_all ~count chunk_key in
      let* () = St.put_manifest ~key ~data:body in
      if !cancel then
        let* () =
          Io.catch
            (fun () -> St.delete_manifest ~key)
            (fun exn ->
              Log.err "upload %s: cancelled-manifest cleanup failed: %s"
                (Logical_key.to_string key)
                (Printexc.to_string exn);
              Io.return ())
        in
        raise Cancelled
      else Io.return state

    (* For a file handed over whole: import, and the FileProvider's re-import.

       Sized from the descriptor the chunks are mapped through, so the length the
       chunking is laid out for and the bytes that reach the store come from one
       file however the name is reused meanwhile.

       [fd] is the source itself, kept alongside the snapshot only to be stat'd
       for whether the file moved while this ran. *)
    let upload ~key ~src_path ~mtime ~chunk_size ?(cancel = ref false)
        ?(on_progress = fun ~bytes:_ ~sent:_ -> ()) () =
      let* fd = Syscalls.openfile src_path [Unix.O_RDONLY] 0 in
      let* table, file_size =
        Io.finalize
          (fun () ->
            let* before = Syscalls.LargeFile.fstat fd in
            (* Frozen here, so a source truncated mid-upload is a manifest never
               published rather than a SIGBUS on a page past its new end. *)
            let snapshot = Bigstring.open_snapshot src_path in
            Io.finalize
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
                  max 1
                    (Chunks.count ~size:(Int64.of_int file_size) ~chunk_size)
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
                let+ after = Syscalls.LargeFile.fstat fd in
                if
                  after.Unix.LargeFile.st_size <> before.Unix.LargeFile.st_size
                  || after.Unix.LargeFile.st_mtime
                     <> before.Unix.LargeFile.st_mtime
                then raise (Source_changed src_path);
                (table, file_size))
              (fun () ->
                Unix.close snapshot;
                Io.return ()))
          (fun () -> Syscalls.close fd)
      in
      publish ~key ~size:(Int64.of_int file_size) ~chunk_size ~mtime ~cancel
        table

    (* Fillers write into a pooled buffer, which is what holds this path to
       [max_chunk_buffers] chunks however wide the fan-out below runs.

       Deciding which case a chunk is must stay free of I/O, or every chunk's bytes
       land before anything queues for a buffer. *)
    let upload_chunks ~key ~size ~chunk_size ~mtime
        ~(source : int -> unit Io.t Chunk_source.t Io.t) ?(cancel = ref false)
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

    (* An unknown folder, an absent object and a body caught mid-write all read
       as no metadata, so a caller reports nothing found rather than garbage. *)
    let fetch_manifest ~key () =
      let+ state = St.get_manifest_state ~key in
      match state with
        | `Unresolved | `Absent -> None
        | `Body body -> (
            match Manifest.of_string body with
              | m -> Some m
              | exception _ -> None)

    let get_chunk ~chunk_key = Chunks_store.fetch chunk_key

    let get_chunk_range ~chunk_key ~offset ~length =
      Chunks_store.fetch_range chunk_key ~offset ~length
  end

  (* The inode layout is what every path-keyed caller wants. *)
  module Make (C : Conf.S with type 'a io = 'a Io.t) =
    Make_with_layout (C) (Inode_layout.Make (C))
end
