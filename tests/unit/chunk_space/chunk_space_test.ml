(* Where a chunk is looked for, and what promoting one does, while its store is
   being collected.

   The three things this pins down are the three the rest of the design leans on:
   a store that will never be collected keeps its single lookup; a lookup during a
   collection finds a chunk in either space; and promoting a chunk that is not in
   the space on its way out does nothing rather than failing — [promote_all] is
   called for every chunk a manifest names, and most of those were just written to
   the surviving space. *)

let root = "/tmp/tsync-chunk-space-test"
let store_dir = root ^ "/store"
let chunk_prefix = "tsync/testdom/chunks/"
let from_prefix = Chunk_space.from_prefix ~chunk_prefix
let marker_key = Chunk_space.marker_key ~chunk_prefix

(* An object store's stand-in: a local backend that says it cannot collect, which
   is what every non-filesystem driver answers. *)
module Uncollectable : Backend.S = struct
  include
    (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some store_dir)
        : Backend.S)

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

module Conf_of (B : Backend.S) : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = chunk_prefix
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"
  let store = (module B : Backend.S)

  (* [local_path] is not decoration here: promoting is a rename within the store's
     own tree, so it is the path and not the module that does it. {!Gc} refuses to
     open a run on a main without one, which is what keeps the two in step. *)
  let members =
    [Backend.member ~role:"main" ~name:"local" ~local_path:store_dir store]

  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Collectable =
  Conf_of
    ((val Backend.make ~backend_type:"local" ~get_field:(fun _ ->
              Some store_dir)
         : Backend.S))

module Space = Chunk_space.Make (Collectable)
module Frozen = Conf_of (Uncollectable)
module Frozen_space = Chunk_space.Make (Frozen)

let case name = Printf.printf "\n=== %s\n" name
let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")

(* A chunk key is "<h1>-<h2>", 16 hex each. Every one of these lands in shard
   [000], which is what this file wants: it is about the two spaces, and keeping
   the chunks in one shard means a path here is wrong for a reason worth
   reading. *)
let ck n = Printf.sprintf "%016x-%016x" n n

module Store =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some store_dir)
      : Backend.S)

let () =
  ignore
    (Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s" root store_dir));
  Lwt_main.run
    (let open Lwt.Syntax in
     let live = ck 1 and going = ck 2 and absent = ck 3 in
     (* [live] in the surviving space, [going] only in the space on its way out —
        the state a half-marked collection is in. *)
     let* () =
       Store.put ~key:(Space.key live) ~data:(Chunk.of_string "live") ()
     in
     let* () =
       Store.put
         ~key:(from_prefix ^ Chunk_layout.relative_path going)
         ~data:(Chunk.of_string "going") ()
     in

     case "idle: one space, and the other is never consulted";
     let* head = Space.head live in
     step "head(live) = %b" (head <> None);
     let* head = Space.head going in
     step "head(in the discarded space) = %b  <- no run, so not looked for"
       (head <> None);
     let* body = Space.get live in
     step "get(live) = %S" (Chunk.to_string body);

     case "a store that cannot collect never grows a second lookup";
     let* head = Frozen_space.head going in
     step "head(in the discarded space) = %b  <- caps.gc = false" (head <> None);

     case "collecting: found in either space";
     (* The lookups above have just cached "idle", and the cache holds for
        seconds, so everything below runs against a stale cache saying no run is
        open. That is the point: finding the chunk anyway is what proves a lookup
        re-reads the marker before reporting a miss, and therefore that the cache
        can only ever cost an extra stat, never an answer. *)
     let* () =
       Space.write_run
         { Chunk_space.phase = Marking; started = 0.; cursor = "" }
     in
     let* head = Space.head live in
     step "head(surviving) = %b" (head <> None);
     let* head = Space.head going in
     step "head(discarded) = %b  <- cache still says idle" (head <> None);
     let* body = Space.get going in
     step "get(discarded) = %S" (Chunk.to_string body);
     let* head = Space.head absent in
     step "head(in neither) = %b" (head <> None);

     case "promoting";
     let* (_ : bool) = Space.promote going in
     let* still = Store.head_opt ~key:(Space.key going) () in
     step "promote gives it a name in the surviving space: %b" (still <> None);
     let* body = Store.get ~key:(Space.key going) () in
     step "and the same bytes: %S" (Chunk.to_string body);
     (* The load-bearing property of the whole scheme: the chunk is *moved*, not
        copied. It is what leaves the space on its way out holding the garbage and
        nothing else, so closing deletes by name instead of working the difference
        out per shard — and it is why marking a multi-terabyte store costs no disk
        and no data movement. A driver that copied instead would double the store
        during a collection and still be green on every other check here, so the
        outgoing name is checked to be gone rather than the bytes to be
        present. *)
     let shard = Chunk_layout.relative_path going in
     let exists p = Sys.file_exists (Filename.concat store_dir p) in
     step "the outgoing name is gone: %b" (not (exists (from_prefix ^ shard)));
     step "one name, one link: nlink=%d"
       (Unix.stat (Filename.concat store_dir (chunk_prefix ^ shard)))
         .Unix.st_nlink;
     let* (_ : bool) = Space.promote going in
     step "promoting twice is not an error";
     (* The case [promote_all] hits constantly: every chunk a manifest names is
        promoted before it is published, and the freshly written ones are in the
        surviving space only. *)
     let* (_ : bool) = Space.promote live in
     step "promoting one that is only in the surviving space is a no-op";
     let* (_ : bool) = Space.promote absent in
     step "promoting one that is in neither space is a no-op";
     let* () = Space.promote_all [live; going; absent] in
     step "promote_all over a mixture moves what is left and leaves the rest";

     case "reading a body still works once the discarded space is gone";
     let* () = Space.clear_run () in
     ignore (Sys.command (Printf.sprintf "rm -rf %s/%s" store_dir from_prefix));
     let* body = Space.get going in
     step "get(promoted) = %S" (Chunk.to_string body);
     let* run = Space.read_run () in
     step "run marker cleared: %b" (run = None);
     step "marker key = %s" marker_key;
     Lwt.return_unit)
