(* The cache-chunk store's contract, against a stub fetcher that counts GETs: a
   body is fetched once and only once, concurrent readers of the same cache chunk
   share that fetch, a body deleted underneath us is fetched again, and the store
   is keyed by content alone (nothing about it is per-file).

   Both granularities are exercised: single-chunk groups (cache chunk size =
   stored chunk size) and a three-chunk group, where one cache file holds three
   backend chunks and a read addresses one member of it.

   The GET counts are the point of the snapshot: they are what proves dedup and
   cache hits, and a regression there is invisible in the returned bytes. *)

open Lwt.Syntax

let root = "/tmp/tsync-chunk-cache-test"

(* What a published chunk is named after. The dedup and cap cases below do not
   care (any distinct name will do), but the integrity check does: it re-derives
   this from the bytes. *)
let key_of body =
  Printf.sprintf "%s-%s" (Xxhash.hash_hex body 0) (Xxhash.hash_hex body 1)

let bodies =
  [
    ("aa11bb22-cc33dd44", "first chunk body");
    ("ee55ff66-0077", "second");
    (* Three chunks of one group; the last is short, as a file's last chunk is. *)
    (key_of "AAAA", "AAAA");
    (key_of "BBBB", "BBBB");
    (key_of "CC", "CC");
  ]

let gets : (string, int) Hashtbl.t = Hashtbl.create 8
let count ck = Option.value ~default:0 (Hashtbl.find_opt gets ck)

module Fetch = struct
  (* Deliberately slow: without a yield inside the fetch, a "concurrent" pair
     would run to completion one after the other and dedup would pass
     trivially. *)
  let get_chunk ~chunk_key =
    Hashtbl.replace gets chunk_key (count chunk_key + 1);
    let* () = Lwt_unix.sleep 0.05 in
    match List.assoc_opt chunk_key bodies with
      | Some b -> Lwt.return b
      | None -> Lwt.fail (Backend.Backend_error ("no such chunk: " ^ chunk_key))
end

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"
  let backends = []
  let cache_root = root
  let data_dir = root
  let socket_path = ""
  let notify_path = ""
  let max_uploads = 1
  let max_downloads = 4
  let chunk_size = 16
  let cache_chunk_size = 48
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Cc = Chunk_cache.Make (C) (Fetch)

(* Same store, seen through a capped config: the cap is the only difference. *)
module Capped20 =
  Chunk_cache.Make
    (struct
      include C

      let max_cache = Some 20
    end)
    (Fetch)

module Capped0 =
  Chunk_cache.Make
    (struct
      include C

      let max_cache = Some 0
    end)
    (Fetch)

let spec ck = Some (ck, String.length (List.assoc ck bodies))
let build ~per specs i = Option.get (Chunk_group.of_specs ~specs ~per i)

(* A group of one: what a domain whose cache chunk size equals its stored chunk
   size gets for every chunk. *)
let solo ck = build ~per:1 [| spec ck |] 0
let g1 = solo (fst (List.nth bodies 0))
let g2 = solo (fst (List.nth bodies 1))
let k3 = fst (List.nth bodies 2)
let k4 = fst (List.nth bodies 3)
let k5 = fst (List.nth bodies 4)

(* One cache file over three backend chunks. *)
let trio_specs = [| spec k3; spec k4; spec k5 |]
let trio = build ~per:3 trio_specs 0

(* The store's own layout rule; the test never recomputes it. *)
let path g =
  Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
    (Chunk_group.key g)

(* Cache-root-relative so the snapshot does not carry a temp path. *)
let rel path =
  let prefix = root ^ "/" in
  if String.starts_with ~prefix path then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

let gets_for g =
  List.fold_left (fun acc ck -> acc + count ck) 0 (Chunk_group.members g)

let show label g =
  let+ present = Lwt.return (Sys.file_exists (path g)) in
  Printf.printf "%-28s present=%-5b gets=%d in_flight=%d\n" label present
    (gets_for g) (Cc.in_flight ())

(* Read one member the way the read path does: into a buffer, by index. *)
let read_member g index =
  let want = Chunk_group.size g index in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout want in
  let+ n = Cc.read_into ~group:g ~index buf ~chunk_off:0 in
  String.init n (Bigarray.Array1.get buf)

let show_body label g index =
  let+ body = read_member g index in
  Printf.printf "%-28s body=%-18S gets=%d\n" label body (gets_for g)

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" root));
  Lwt_main.run
    (let* () = show "cold" g1 in

     (* Two readers, one GET. *)
     let* () = Lwt.join [Cc.ensure ~group:g1 (); Cc.ensure ~group:g1 ()] in
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

     (* ── Grouped: three stored chunks, one cache file ─────────────────────── *)
     (* One cache miss costs one GET per member, and lands as a single file. *)
     let* () = show "trio cold" trio in
     let* () = show_body "trio member 0" trio 0 in
     Printf.printf "%-28s %s\n" "layout" (rel (path trio));
     Printf.printf "%-28s bytes=%d members=%d\n" "trio body"
       (Chunk_group.bytes trio)
       (Chunk_group.member_count trio);

     (* The other members came down with it: reading them costs nothing more,
        and each lands at its own offset inside the one file. *)
     let* () = show_body "trio member 1 (cached)" trio 1 in
     let* () = show_body "trio member 2 (cached)" trio 2 in
     Printf.printf "%-28s off0=%d off1=%d off2=%d\n" "trio offsets"
       (Chunk_group.offset trio 0)
       (Chunk_group.offset trio 1)
       (Chunk_group.offset trio 2);

     (* A partial read inside a member is still addressed by member offset. *)
     let* () =
       let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 2 in
       let+ n = Cc.read_into ~group:trio ~index:1 buf ~chunk_off:2 in
       Printf.printf "%-28s body=%S\n" "trio member 1 at +2"
         (String.init n (Bigarray.Array1.get buf))
     in

     (* Grouping is content-addressed like any chunk: the same three chunks in
        another file are the same cache file, already here. *)
     let same = build ~per:3 [| spec k3; spec k4; spec k5 |] 2 in
     Printf.printf "%-28s same_key=%b\n" "trio in another file"
       (Chunk_group.key same = Chunk_group.key trio);

     (* A backend failure surfaces rather than caching an empty body. *)
     let* () =
       Lwt.catch
         (fun () ->
           let missing = build ~per:1 [| Some ("deadbeef-deadbeef", 4) |] 0 in
           let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4 in
           let+ (_ : int) =
             Cc.read_into ~group:missing ~index:0 buf ~chunk_off:0
           in
           Printf.printf "%-28s no error\n" "missing chunk")
         (fun exn ->
           Printf.printf "%-28s %s in_flight=%d\n" "missing chunk"
             (Printexc.to_string exn) (Cc.in_flight ());
           Lwt.return_unit)
     in

     (* ── Integrity ────────────────────────────────────────────────────────── *)
     (* A group body cannot be checked against its own name, so verification
        hashes each member segment against the key it was published under. *)
     let* ok = Cc.verify_group ~group:trio in
     Printf.printf "%-28s ok=%b\n" "verify intact group" ok;
     let* () =
       Lwt_io.with_file ~mode:Lwt_io.Output ~flags:[Unix.O_WRONLY] (path trio)
         (fun oc ->
           let* () = Lwt_io.set_position oc 5L in
           Lwt_io.write oc "X")
     in
     let* ok = Cc.verify_group ~group:trio in
     Printf.printf "%-28s ok=%-5b present=%b\n" "verify corrupt member" ok
       (Sys.file_exists (path trio));

     (* ── Cache cap ────────────────────────────────────────────────────────── *)
     (* Explicit mtimes: coldest-first ordering must not depend on filesystem
        timestamp resolution. *)
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
     let+ () = show_cap "cap=0 (drops all)" in
     ())
