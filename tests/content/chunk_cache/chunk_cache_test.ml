(* The cache-chunk store's contract, against a stub fetcher counting GETs: a body
   is fetched once, concurrent readers of one cache chunk share that fetch, a body
   deleted underneath is fetched again, and the store is keyed by content alone.

   Both granularities are exercised: single-chunk groups, and a three-chunk group
   where one cache file holds three backend chunks and a read addresses one
   member.

   The GET counts are the point of the snapshot — they prove dedup and cache
   hits, and a regression there is invisible in the returned bytes. *)

open Lwt.Syntax

let root = "/tmp/tsync-chunk-cache-test"

(* The dedup and cap cases below take any distinct name, but the integrity check
   re-derives this from the bytes. *)
let key_of body =
  Printf.sprintf "%s-%s" (Xxhash.hash_hex body 0) (Xxhash.hash_hex body 1)

(* Keys are a fixed width, so even the content-agnostic stand-ins must be shaped
   like real ones. *)
let bodies =
  [
    (key_of "first chunk body", "first chunk body");
    (key_of "second", "second");
    (* Three chunks of one group; the last is short, as a file's last chunk is. *)
    (key_of "AAAA", "AAAA");
    (key_of "BBBB", "BBBB");
    (key_of "CC", "CC");
    (* A second group, for the whole-group fetch, which needs one nothing has
       touched. *)
    (key_of "DDDD", "DDDD");
    (key_of "EEEE", "EEEE");
    (key_of "FF", "FF");
  ]

let gets : (string, int) Hashtbl.t = Hashtbl.create 8
let count ck = Option.value ~default:0 (Hashtbl.find_opt gets ck)

(* Counted apart from whole-chunk gets, and by the bytes as well as the calls: a
   range read that quietly asked for the whole chunk would be indistinguishable
   from one that asked for eight bytes if only the calls were counted. *)
let ranges : (string, (int * int) list) Hashtbl.t = Hashtbl.create 8
let asked ck = Option.value ~default:[] (Hashtbl.find_opt ranges ck)

let range_summary ck =
  match List.rev (asked ck) with
    | [] -> "none"
    | rs ->
        String.concat " "
          (List.map (fun (o, l) -> Printf.sprintf "[%d,%d)" o (o + l)) rs)

(* Overlap is what shows whether a group's members are fetched concurrently, and
   unlike elapsed time it does not depend on machine load. *)
let in_fetch = ref 0
let peak_in_fetch = ref 0
let watch_overlap () = peak_in_fetch := !in_fetch

module Fetch = struct
  (* Deliberately slow: without a yield inside the fetch, concurrent callers run
     to completion in turn, dedup passes trivially and no overlap is
     observable. *)
  let get_chunk ~chunk_key =
    Hashtbl.replace gets chunk_key (count chunk_key + 1);
    incr in_fetch;
    if !in_fetch > !peak_in_fetch then peak_in_fetch := !in_fetch;
    Lwt.finalize
      (fun () ->
        let* () = Lwt_unix.sleep 0.05 in
        match List.assoc_opt chunk_key bodies with
          | Some b -> Lwt.return (Bigstring.of_string b)
          | None ->
              Lwt.fail (Backend.Backend_error ("no such chunk: " ^ chunk_key)))
      (fun () ->
        decr in_fetch;
        Lwt.return_unit)

  let get_chunk_range ~chunk_key ~offset ~length =
    Hashtbl.replace ranges chunk_key ((offset, length) :: asked chunk_key);
    incr in_fetch;
    if !in_fetch > !peak_in_fetch then peak_in_fetch := !in_fetch;
    Lwt.finalize
      (fun () ->
        let* () = Lwt_unix.sleep 0.05 in
        match List.assoc_opt chunk_key bodies with
          | Some b ->
              Lwt.return
                (Bigstring.of_string
                   (String.sub b offset
                      (max 0 (min length (String.length b - offset)))))
          | None ->
              Lwt.fail (Backend.Backend_error ("no such chunk: " ^ chunk_key)))
      (fun () ->
        decr in_fetch;
        Lwt.return_unit)
end

(* Nothing here reaches a store: the fetch function is supplied directly. A
   backend that raises makes that explicit rather than quietly succeeding. *)
let unused_store : (module Backend_lwt.Store) =
  (module Doubles.Down (struct
    let why = "no backend in this test"
  end))

module C : Conf_lwt.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/testdom/" "cursor"
  let shares_prefix = "tsync/shares/"
  let store = unused_store
  let members = []
  let cache_root = root
  let data_dir = root
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 4
  let chunk_size = Some 16
  let cache_chunk_size = Some 48
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false

  include Conf_lwt.Monad
end

module Cc = Chunk_cache_lwt.Make (C) (Fetch)
module Sb = Staged_lwt.Body.Make (C) (Cc)

(* Same store, seen through a capped config: the cap is the only difference. *)
module Capped20 =
  Chunk_cache_lwt.Make
    (struct
      include C

      let max_cache = Some 20
    end)
    (Fetch)

module Capped0 =
  Chunk_cache_lwt.Make
    (struct
      include C

      let max_cache = Some 0
    end)
    (Fetch)

(* Chunk lengths derive from the header, so file size and chunk size set
   them. *)
let table ~chunk_size ~size keys =
  Manifest.of_string
    (Manifest.encode ~name:"t" ~size:(Int64.of_int size) ~chunk_size ~mtime:0.
       ~h1:(String.make 16 '0') ~h2:(String.make 16 '0') ~symlink:None ~keys)

let build ~per ~chunk_size ~size keys i =
  Option.get
    (Manifest.Group.of_table ~table:(table ~chunk_size ~size keys) ~per i)

(* What a domain whose cache chunk size equals its stored chunk size gets. *)
let solo ck =
  let n = String.length (List.assoc ck bodies) in
  build ~per:1 ~chunk_size:n ~size:n [ck] 0

let g1 = solo (fst (List.nth bodies 0))
let g2 = solo (fst (List.nth bodies 1))
let k3 = fst (List.nth bodies 2)
let k4 = fst (List.nth bodies 3)
let k5 = fst (List.nth bodies 4)

let k6 = fst (List.nth bodies 5)
let k7 = fst (List.nth bodies 6)
let k8 = fst (List.nth bodies 7)

(* One cache file over three backend chunks: 4 + 4 + 2, the last one short. *)
let trio_table = table ~chunk_size:4 ~size:10 [k3; k4; k5]
let trio = Option.get (Manifest.Group.of_table ~table:trio_table ~per:3 0)
let whole_table = table ~chunk_size:4 ~size:10 [k6; k7; k8]
let whole_trio = Option.get (Manifest.Group.of_table ~table:whole_table ~per:3 0)

(* The store's own rules; never recomputed here. *)
let manifest_path g =
  Cache_layout.chunk_manifest_path ~cache_root:C.cache_root
    ~domain_name:C.domain_name (Manifest.Group.key g)

let path g =
  Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
    (Manifest.Group.key g)

(* Cache-root-relative so the snapshot does not carry a temp path. *)
let rel path =
  let prefix = root ^ "/" in
  if String.starts_with ~prefix path then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

(* The group's member keys, in index order. *)
let members g =
  List.init (Manifest.Group.member_count g) (Manifest.Group.member_key g)

let gets_for g = List.fold_left (fun acc ck -> acc + count ck) 0 (members g)

let show label g =
  let+ present = Lwt.return (Sys.file_exists (path g)) in
  Printf.printf "%-28s present=%-5b gets=%d in_flight=%d\n" label present
    (gets_for g) (Cc.in_flight ())

(* As the read path does: into a buffer, by index. *)
let read_member g index =
  let want = Manifest.Group.size g index in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout want in
  let+ served = Cc.read_into ~group:g ~index buf ~chunk_off:0 in
  ( String.init served.Chunk_cache.bytes (Bigarray.Array1.get buf),
    served.Chunk_cache.from_backend )

let show_body label g index =
  let+ body, from_backend = read_member g index in
  Printf.printf "%-28s body=%-18S gets=%d backend=%b\n" label body (gets_for g)
    from_backend

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" root));
  Lwt_main.run
    (let* () = show "cold" g1 in

     (* Two readers, one GET, and both told it came from a backend -- the one
        that only joined waited on the network just as the other did. *)
     let* () =
       let+ fetched =
         Lwt.all
           [Cc.ensure_fetched ~group:g1 (); Cc.ensure_fetched ~group:g1 ()]
       in
       Printf.printf "%-28s backend=%s\n" "2 concurrent ensures"
         (String.concat "," (List.map string_of_bool fetched))
     in
     let* () = show "after 2 concurrent ensures" g1 in

     (* Already present: no GET at all. *)
     let* () = show_body "cached read" g1 0 in
     Printf.printf "%-28s %s\n" "layout" (rel (path g1));

     (* Evicted underneath us: the read fetches it back rather than failing. *)
     let* () = Cc.forget ~group:g1 in
     let* () = show_body "read after eviction" g1 0 in

     (* A body believed corrupt is refetched on demand. *)
     let* () = Cc.ensure ~force:true ~group:g1 () in
     let* () = show "forced refetch" g1 in

     (* A distinct key is a distinct body, sharing nothing with the first. *)
     let* () = show_body "second key" g2 0 in
     Printf.printf "%-28s %s\n" "layout" (rel (path g2));

     (* A read takes the bytes it asked for and no more: one range against the
        member it names, and nothing at all for the two beside it. *)
     let* () = show "trio cold" trio in
     let* () = show_body "trio member 0" trio 0 in
     Printf.printf "%-28s %s / %s / %s\n" "trio ranges asked"
       (range_summary k3) (range_summary k4) (range_summary k5);
     Printf.printf "%-28s %s\n" "layout" (rel (path trio));
     Printf.printf "%-28s bytes=%d members=%d\n" "trio body"
       (Manifest.Group.bytes trio)
       (Manifest.Group.member_count trio);

     (* Kept: the same bytes read again cost nothing, which is what a partly
        filled body is for. *)
     let* () = show_body "trio member 0 again" trio 0 in
     Printf.printf "%-28s %s\n" "trio ranges after re-read" (range_summary k3);

     (* The neighbours were never fetched, so each costs its own range. *)
     let* () = show_body "trio member 1" trio 1 in
     let* () = show_body "trio member 2" trio 2 in
     Printf.printf "%-28s %s / %s / %s\n" "trio ranges after all three"
       (range_summary k3) (range_summary k4) (range_summary k5);
     (* Every member whole makes the body whole, and the manifest that said
        otherwise is what its absence now denies. *)
     Printf.printf "%-28s partial=%b\n" "trio body after all three"
       (Sys.file_exists (path trio ^ Cache_layout.manifest_suffix));
     Printf.printf "%-28s off0=%d off1=%d off2=%d\n" "trio offsets"
       (Manifest.Group.offset trio 0)
       (Manifest.Group.offset trio 1)
       (Manifest.Group.offset trio 2);

     (* Whole-group fetching is what read-ahead and materialization do, and it
        is where members are fetched together: all three are in the fetcher at
        once, each writing its own offset, so a cold group costs about one round
        trip. Serial fetching peaks at 1. *)
     watch_overlap ();
     let* () = Cc.ensure ~group:whole_trio () in
     Printf.printf "%-28s peak_concurrent_gets=%d of %d\n"
       "whole group concurrency" !peak_in_fetch
       (Manifest.Group.member_count whole_trio);
     let* () = show "whole group" whole_trio in

     (* A partial read inside a member is still addressed by member offset. *)
     let* () =
       let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 2 in
       let+ served = Cc.read_into ~group:trio ~index:1 buf ~chunk_off:2 in
       Printf.printf "%-28s body=%S\n" "trio member 1 at +2"
         (String.init served.Chunk_cache.bytes (Bigarray.Array1.get buf))
     in

     (* Content-addressed like any chunk: the same three chunks in another file
        are the same cache file, already here. *)
     let same = build ~per:3 ~chunk_size:4 ~size:10 [k3; k4; k5] 2 in
     Printf.printf "%-28s same_key=%b\n" "trio in another file"
       (Manifest.Group.key same = Manifest.Group.key trio);

     (* A backend failure surfaces rather than caching an empty body. *)
     let* () =
       Lwt.catch
         (fun () ->
           let missing =
             build ~per:1 ~chunk_size:4 ~size:4 [key_of "never uploaded"] 0
           in
           let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4 in
           let+ (_ : Chunk_cache.served) =
             Cc.read_into ~group:missing ~index:0 buf ~chunk_off:0
           in
           Printf.printf "%-28s no error\n" "missing chunk")
         (fun exn ->
           Printf.printf "%-28s %s in_flight=%d\n" "missing chunk"
             (Printexc.to_string exn) (Cc.in_flight ());
           Lwt.return_unit)
     in

     (* Explicit mtimes: ordering must not depend on filesystem timestamp
        resolution. *)
     Unix.utimes (path g1) 1000. 1000.;
     Unix.utimes (path g2) 2000. 2000.;
     let show_cap label =
       let+ chunks, bytes = Cc.stats () in
       let p1 = Sys.file_exists (path g1) in
       let p2 = Sys.file_exists (path g2) in
       Printf.printf "%-28s chunks=%d bytes=%2d first=%-5b second=%b\n" label
         chunks bytes p1 p2
     in
     let* () = show_cap "uncapped" in
     let* () = Cc.enforce_cap () in
     let* () = show_cap "cap=none (no-op)" in
     let* () = Capped20.enforce_cap () in
     (* 22 bytes over a 20-byte cap: the colder chunk goes, the warmer stays. *)
     let* () = show_cap "cap=20 (drops coldest)" in
     (* A dropped chunk is not lost, just not local. *)
     let* () = show_body "refetch after cap" g1 0 in
     let* () = Capped0.enforce_cap () in
     let* () = show_cap "cap=0 (drops all)" in

     (* A partly filled body and its manifest are one thing to the cap. Evicting
        the body alone would leave a manifest describing bytes that are gone;
        evicting the manifest alone would leave a body with holes in it that
        every reader takes for whole, and serve those holes as content. *)
     let partial = manifest_path whole_trio in
     let* (_ : string * bool) = read_member whole_trio 0 in
     Printf.printf "%-28s body=%b manifest=%b\n" "partly filled again"
       (Sys.file_exists (path whole_trio))
       (Sys.file_exists partial);
     let* () = Capped0.enforce_cap () in
     Printf.printf "%-28s body=%b manifest=%b\n" "cap=0 over a partial body"
       (Sys.file_exists (path whole_trio))
       (Sys.file_exists partial);
     (* And what it reads afterwards is the chunk, not the hole. *)
     let* () = show_body "read after the pair goes" whole_trio 0 in

     (* Publishing a group that was staged in its own layout: the bytes get a
        second name rather than a second copy, so both are readable until the
        staged one goes and the cache keeps the body afterwards. *)
     let uuid = "stagedbody000001" in
     let bytes = Manifest.Group.bytes trio in
     let* () = Sb.ensure ~uuid ~len:bytes in
     let* () =
       Lwt_list.iter_s
         (fun (i, body) ->
           let buf =
             Bigarray.Array1.of_array Bigarray.char Bigarray.c_layout
               (Array.init (String.length body) (String.get body))
           in
           let+ (_ : int) =
             Sb.write ~uuid buf ~offset:(Manifest.Group.offset trio i)
           in
           ())
         [(0, "AAAA"); (1, "BBBB"); (2, "CC")]
     in
     let* linked = Sb.link_group ~uuid ~len:bytes ~group:trio in
     let staged = Sb.path uuid in
     let same_inode () =
       (Unix.stat staged).Unix.st_ino = (Unix.stat (path trio)).Unix.st_ino
     in
     Printf.printf "%-28s linked=%b one body=%b names=%d\n" "publish by link"
       linked (same_inode ()) (Unix.stat (path trio)).Unix.st_nlink;
     let* again = Sb.link_group ~uuid ~len:bytes ~group:trio in
     Printf.printf "%-28s linked=%b\n" "publishing it again" again;
     let* disagreeing = Sb.link_group ~uuid ~len:(bytes + 1) ~group:trio in
     Printf.printf "%-28s linked=%b\n" "a length that disagrees" disagreeing;
     let* () = Sb.forget ~uuid in
     let* () = show_body "read after the staged name goes" trio 1 in
     let* () = show_body "and its short last member" trio 2 in

     (* Nothing tells the cap to spare unsynced bytes: they are in a tree it
        does not sweep, so a cap of zero cannot reach them. *)
     let unpublished = "stagedbody000002" in
     let* () = Sb.ensure ~uuid:unpublished ~len:4 in
     let* () = Capped0.enforce_cap () in
     let+ chunks, _ = Cc.stats () in
     Printf.printf "%-28s staged=%b cache chunks=%d\n"
       "cap=0 over a staged body"
       (Sys.file_exists (Sb.path unpublished))
       chunks)
