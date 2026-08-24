(* The two bounds a mirror runs under, and the hook that says where it is.

   A copy holds a whole object body and a HEAD holds none, so one bound cannot
   stand for both: sizing a subtree behind the body budget queues round trips
   against memory they never use, and the [slots] row in [tsync status] would be
   naming a resource that is not the one filling up.

   [on_copy] fires once an object is done, so it cannot answer "what is it on
   right now" for an object still being fetched — which is every large chunk,
   for as long as it takes. *)

open Lwt.Syntax
open Check

let root = "/tmp/tsync-mirror-pools-test"
let src_dir = root ^ "/src"
let dst_dir = root ^ "/dst"
let domain_prefix = "tsync/testdom/manifests/"

module Src =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some src_dir) ()
      : Backend.S)

module Dst =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some dst_dir) ()
      : Backend.S)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = domain_prefix
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/testdom/" "cursor"
  let shares_prefix = "tsync/shares/"

  let members =
    [
      Backend.member ~role:`Main ~backend_type:"local" ~local_path:src_dir
        ~name:"source"
        (module Src);
      Backend.member ~role:`Replica ~backend_type:"local" ~local_path:dst_dir
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

let pool name =
  List.find_opt (fun (n, _, _, _) -> n = name) (Lwt_bounded.totals ())

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root src_dir dst_dir));
  Lwt_main.run
    (case "a bound names the resource it protects";
     (* Unnamed, they are absent from every report: the row that tells work
        queued behind a bound from work merely slow is built from this list. *)
     check "the body bound is registered" (pool "copy" <> None);
     check "the round-trip bound is registered" (pool "probe" <> None);
     (match (pool "copy", pool "probe") with
       | Some (_, _, _, copy), Some (_, _, _, probe) ->
           step "copy admits %d, probe %d" copy probe;
           check "a HEAD holds no body, so the two are not one number"
             (probe > copy)
       | _ -> check "both bounds exist to compare" false);

     case "what a copy is on, before it is done";
     let* () =
       Lwt_list.iter_s
         (fun n ->
           Src.put
             ~key:
               (Stored_key.in_space ~prefix:domain_prefix
                  (Printf.sprintf "folder/%04d" n))
             ~data:(Bigstring.of_string (String.make (8 + n) 'x'))
             ())
         (List.init 2000 (fun i -> i))
     in
     (* The order events arrive in, which is the whole question: announcing
        before the bound is announcing every object at once. *)
     let events = ref [] in
     let started = ref [] and finished = ref [] in
     (* Sampled once, when the first object finishes: that is the moment a
        promise-per-entry shape is holding the whole listing's worth at once. *)
     let live_at_first_copy = ref 0 in
     let baseline = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words in
     let* dests =
       M.resync ~source:"source" ~scope:`Manifests
         ~on_start:(fun ~name:_ ~key ->
           events := `Start :: !events;
           started := key :: !started)
         ~on_entry:(fun ~name:_ ~key ~size:_ ~outcome:_ ->
           if !live_at_first_copy = 0 then
             live_at_first_copy :=
               (Stdlib.Gc.stat ()).Stdlib.Gc.live_words - baseline;
           events := `Copy :: !events;
           finished := key :: !finished)
         ()
     in
     let copied = List.fold_left (fun n d -> n + d.Mirror.copied) 0 dests in
     step "%d object(s) picked up, %d copied" (List.length !started) copied;
     check "every object was announced before the run ended"
       (List.length !started = copied);
     (* Announced and finished must be the same set, or a caller shows a key
        that was never worked on. *)
     check "and the two accounts name the same objects"
       (List.sort compare !started = List.sort compare !finished);
     check "each object was announced once"
       (List.length (List.sort_uniq compare !started) = List.length !started);
     (* An announcement made from inside the bound cannot outrun the bound, so
        only what is in flight can have been announced before the first object
        finishes; one made as the list is laid out announces all of it. *)
     let announced_before_first_copy =
       let rec go n = function
         | `Copy :: _ | [] -> n
         | `Start :: rest -> go (n + 1) rest
       in
       go 0 (List.rev !events)
     in
     step "announced before the first object finished: %d of %d"
       announced_before_first_copy (List.length !started);
     (* The listing is on disk and read a record at a time, so what a run holds
        per object is what the object in flight costs and nothing else: three
        words, against a hundred and forty for a promise, a closure and a queue
        cell apiece. The threshold is set just above what the shape achieves,
        since a bound nothing can reach says nothing. *)
     let per_object = !live_at_first_copy / List.length !started in
     check "what is held does not grow with the length of the listing"
       ~why:(fun () ->
         Printf.sprintf "%d words for %d objects, %d each" !live_at_first_copy
           (List.length !started) per_object)
       (per_object < 8);
     check "an object is announced when it is picked up, not when the list is"
       ~why:(fun () ->
         Printf.sprintf "%d of %d announced before any work finished"
           announced_before_first_copy (List.length !started))
       (announced_before_first_copy < List.length !started);

     (* A second pass has nothing to do, so nothing may be announced as picked
        up: [on_start] fires per object examined, and every one is already
        right. *)
     let started = ref [] and copies = ref 0 and present = ref 0 in
     let* dests =
       M.resync ~source:"source" ~scope:`Manifests
         ~on_start:(fun ~name:_ ~key -> started := key :: !started)
         ~on_entry:(fun ~name:_ ~key:_ ~size:_ ~outcome ->
           match outcome with
             | `Copied _ -> incr copies
             | `Present -> incr present)
         ()
     in
     step "second pass: %d examined, %d copied" (List.length !started) !copies;
     check "a settled destination is still examined"
       (List.length !started = copied);
     check "and nothing is copied twice" (!copies = 0);
     (* An object found in place is what the run got through, and a caller told
        only about copies would have a second pass report no progress at all. *)
     check "an object already right is still accounted for"
       ~why:(fun () -> Printf.sprintf "%d of %d" !present copied)
       (!present = copied);
     check "which the stats agree with"
       (List.for_all (fun d -> d.Mirror.copied = 0) dests);

     report ~expected:12 ();
     Lwt.return_unit)
