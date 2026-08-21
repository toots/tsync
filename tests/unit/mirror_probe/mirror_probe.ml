(* How a mirror asks each side what it holds.

   The source is enumerated by listing, and asking the destination the same
   question one object at a time costs a round trip each where a listing answers
   a thousand keys at once. What is counted here is therefore requests, not
   time: a HEAD apiece and a listing are both correct and only one of them
   finishes.

   The chunk prefix is the exception, and the second case is what says so: it is
   the shared store of every domain on the bucket, so it is asked for a shard at
   a time, which is a listing per shard and a working set that follows the shard
   rather than the bucket. *)

open Lwt.Syntax

let root = "/tmp/tsync-mirror-probe-test"
let src_dir = root ^ "/src"
let dst_dir = root ^ "/dst"
let domain_prefix = "tsync/testdom/manifests/"
let objects = 200

module Src =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some src_dir) ()
      : Backend.S)

module Real =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some dst_dir) ()
      : Backend.S)

let heads = ref 0
let listings = ref 0

(* Counts what the destination is asked, and answers exactly as the store
   underneath would. *)
module Dst : Backend.S = struct
  include Real

  let head_opt ~key () =
    incr heads;
    Real.head_opt ~key ()

  let list_prefix ?max_keys ~prefix () =
    incr listings;
    Real.list_prefix ?max_keys ~prefix ()
end

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = domain_prefix
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"

  let members =
    [
      Backend.member ~role:"main" ~backend_type:"local" ~local_path:src_dir
        ~name:"source"
        (module Src);
      Backend.member ~role:"replica" ~backend_type:"local" ~local_path:dst_dir
        ~name:"copy"
        (module Dst);
    ]

  let store =
    Domain_store.make
      ~mains:[{ Domain_store.name = "source"; backend = (module Src) }]
      ~targets:[]
      ~archives:[{ Domain_store.name = "copy"; backend = (module Dst) }]

  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 2
  let max_downloads = 1
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module M = Mirror.Make (C)

let key n = Printf.sprintf "%sfolder/%04d" domain_prefix n
let body n = Chunk.of_string (String.make (8 + n) 'x')

(* Enough shards touched that a listing of the whole prefix and a listing per
   shard cannot be confused for one another. *)
let chunk_shards = ["000"; "001"; "fff"]

let chunk_key shard n =
  Printf.sprintf "%s%s/%s0000000000000-%016x" C.chunk_prefix shard shard n

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" root));
  Lwt_main.run
    (let* () =
       Lwt_list.iter_s
         (fun n -> Src.put ~key:(key n) ~data:(body n) ())
         (List.init objects (fun i -> i))
     in
     (* Every other one, so both answers are exercised. *)
     let* () =
       Lwt_list.iter_s
         (fun n -> Real.put ~key:(key n) ~data:(body n) ())
         (List.init (objects / 2) (fun i -> i * 2))
     in
     heads := 0;
     listings := 0;
     let* dests = M.resync ~source:"source" ~scope:`Manifests () in
     let copied = List.fold_left (fun n d -> n + d.Mirror.copied) 0 dests in
     let checked = List.fold_left (fun n d -> n + d.Mirror.checked) 0 dests in
     Printf.printf "=== a mirror over a namespace\n";
     Printf.printf "  objects          %d\n" objects;
     Printf.printf "  checked          %d\n" checked;
     Printf.printf "  already there    %d\n" (checked - copied);
     Printf.printf "  copied           %d\n" copied;
     Printf.printf "  head_opt         %d\n" !heads;
     Printf.printf "  list_prefix      %d\n" !listings;

     let* () =
       Lwt_list.iter_s
         (fun shard ->
           Lwt_list.iter_s
             (fun n -> Src.put ~key:(chunk_key shard n) ~data:(body n) ())
             (List.init 4 (fun i -> i)))
         chunk_shards
     in
     heads := 0;
     listings := 0;
     let+ dests = M.resync ~source:"source" ~scope:`All () in
     let copied = List.fold_left (fun n d -> n + d.Mirror.copied) 0 dests in
     let planted = List.length chunk_shards * 4 in
     Printf.printf "\n=== a mirror over the whole store\n";
     Printf.printf "  chunks planted        %d\n" planted;
     Printf.printf "  all of them copied    %b\n" (copied >= planted);
     Printf.printf "  head_opt              %d\n" !heads;
     Printf.printf "  listed shard by shard %b\n"
       (!listings > Chunk_layout.shards))
