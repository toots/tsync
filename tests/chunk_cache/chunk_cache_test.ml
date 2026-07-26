(* The chunk store's contract, against a stub fetcher that counts GETs: a body is
   fetched once and only once, concurrent readers of the same chunk share that
   fetch, a body deleted underneath us is fetched again, and the store is keyed by
   content alone (nothing about it is per-file).

   The GET counts are the point of the snapshot: they are what proves dedup and
   cache hits, and a regression there is invisible in the returned bytes. *)

open Lwt.Syntax

let root = "/tmp/tsync-chunk-cache-test"

let bodies =
  [("aa11bb22-cc33dd44", "first chunk body"); ("ee55ff66-0077", "second")]

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

let ck1 = fst (List.nth bodies 0)
let ck2 = fst (List.nth bodies 1)

(* The store's own layout rule; the test never recomputes it. *)
let path ck =
  Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name ck

(* Cache-root-relative so the snapshot does not carry a temp path. *)
let rel path =
  let prefix = root ^ "/" in
  if String.starts_with ~prefix path then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

let show label ck =
  let+ present = Lwt.return (Sys.file_exists (path ck)) in
  Printf.printf "%-28s present=%-5b gets=%d in_flight=%d\n" label present
    (count ck) (Cc.in_flight ())

(* Read a whole body the way the read path does: into a buffer, per chunk. *)
let read_body ck =
  let want = String.length (List.assoc ck bodies) in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout want in
  let+ n = Cc.read_into ~chunk_key:ck buf ~chunk_off:0 in
  String.init n (Bigarray.Array1.get buf)

let show_body label ck =
  let+ body = read_body ck in
  Printf.printf "%-28s body=%-18S gets=%d\n" label body (count ck)

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" root));
  Lwt_main.run
    (let* () = show "cold" ck1 in

     (* Two readers, one GET. *)
     let* () =
       Lwt.join [Cc.ensure ~chunk_key:ck1 (); Cc.ensure ~chunk_key:ck1 ()]
     in
     let* () = show "after 2 concurrent ensures" ck1 in

     (* Already present: no GET at all. *)
     let* () = show_body "cached read" ck1 in
     Printf.printf "%-28s %s\n" "layout" (rel (path ck1));

     (* Evicted underneath us: the read fetches it back rather than failing. *)
     let* () = Cc.forget ~chunk_key:ck1 in
     let* () = show_body "read after eviction" ck1 in

     (* A body believed corrupt is refetched on demand. *)
     let* () = Cc.ensure ~force:true ~chunk_key:ck1 () in
     let* () = show "forced refetch" ck1 in

     (* A distinct key is a distinct body, sharing nothing with the first. *)
     let* () = show_body "second key" ck2 in
     Printf.printf "%-28s %s\n" "layout" (rel (path ck2));

     (* A backend failure surfaces rather than caching an empty body. *)
     let* () =
       Lwt.catch
         (fun () ->
           let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout 4 in
           let+ (_ : int) =
             Cc.read_into ~chunk_key:"deadbeef-deadbeef" buf ~chunk_off:0
           in
           Printf.printf "%-28s no error\n" "missing chunk")
         (fun exn ->
           Printf.printf "%-28s %s in_flight=%d\n" "missing chunk"
             (Printexc.to_string exn) (Cc.in_flight ());
           Lwt.return_unit)
     in

     (* ── Cache cap ────────────────────────────────────────────────────────── *)
     (* Explicit mtimes: coldest-first ordering must not depend on filesystem
        timestamp resolution. *)
     Unix.utimes (path ck1) 1000. 1000.;
     Unix.utimes (path ck2) 2000. 2000.;
     let show_cap label =
       let+ chunks, bytes = Cc.stats () in
       let p1 = Sys.file_exists (path ck1) in
       let p2 = Sys.file_exists (path ck2) in
       Printf.printf "%-28s chunks=%d bytes=%2d %s=%-5b %s=%b\n" label chunks
         bytes ck1 p1 ck2 p2
     in
     let* () = show_cap "uncapped" in
     let* () = Cc.enforce_cap () in
     let* () = show_cap "cap=none (no-op)" in
     let* () = Capped20.enforce_cap () in
     (* 22 bytes over a 20-byte cap: the colder chunk goes, the warmer stays. *)
     let* () = show_cap "cap=20 (drops coldest)" in
     (* A dropped chunk is not lost, just not local. *)
     let* () = show_body "refetch after cap" ck1 in
     let* () = Capped0.enforce_cap () in
     let+ () = show_cap "cap=0 (drops all)" in
     ())
