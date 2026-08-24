(* Share manifest construction: a file path yields a [type:file] manifest keyed
   by the file's manifest key; a directory (here the domain root) yields a
   [type:dir] manifest carrying the folder's namespace prefix and a .zip name.
   Also guards that the manifest lands under the domain's shares/ prefix. *)

let root = "/tmp/tsync-share-test"
let store_dir = root ^ "/store"
let cache_dir = root ^ "/cache"
let data_dir = root ^ "/data"
let share_base = "https://share.example"

(* A local backend that also advertises a share URL (a plain local backend
   never serves shares). *)
module Shareable : Backend.S = struct
  include
    (val Backend.make ~backend_type:"local"
           ~get_field:(fun _ -> Some store_dir)
           ()
        : Backend.S)

  let get_many = None

  let capabilities ~prefix:_ () =
    Lwt.return { Backend.no_caps with share_url = Some share_base }
end

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/testdom/" "cursor"
  let shares_prefix = "tsync/shares/"
  let store = (module Shareable : Backend.S)
  let members = [Backend.member ~name:"local" store]
  let cache_root = cache_dir
  let data_dir = data_dir
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some (8 * 1024 * 1024)
  let cache_chunk_size = Some (8 * 1024 * 1024)
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Lk = Logical_key.Make (C)

let shares_prefix = "tsync/shares/"

module L = Layout.Inode.Make (C)
module S = Share.Make (C)

let member key json =
  match json with `Assoc l -> List.assoc key l | _ -> assert false

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s %s" root store_dir cache_dir
          data_dir));
  let (module B : Backend.S) = (module Shareable) in
  Lwt_main.run
    (let open Lwt.Syntax in
     (* File: put a (non-marker) manifest, share it. *)
     let* file_key = L.ensure_manifest_key (Lk.file "foo") in
     let* () =
       B.put ~key:file_key ~data:(Bigstring.of_string "{\"chunks\":[]}") ()
     in
     let* url = S.create ~token:"aa" ~expires:123 ~rel:"foo" () in
     let url = match url with Ok u -> u | Error e -> failwith e in
     assert (url = share_base ^ "/aa");
     let* body =
       B.get ~key:(Stored_key.in_space ~prefix:shares_prefix "aa") ()
     in
     let m = Yojson.Basic.from_string (Bigstring.to_string body) in
     assert (member "type" m = `String "file");
     assert (member "key" m = `String (Stored_key.to_string file_key));
     assert (member "filename" m = `String "foo");
     assert (member "expires" m = `Int 123);

     let* () =
       B.put
         ~key:
           (Stored_key.in_space ~prefix:C.domain_prefix
              (Stored_key.root_id ^ "/x"))
         ~data:(Bigstring.of_string "x") ()
     in
     let* url = S.create ~token:"bb" ~expires:123 ~rel:"" () in
     let url = match url with Ok u -> u | Error e -> failwith e in
     assert (url = share_base ^ "/bb");
     let* body =
       B.get ~key:(Stored_key.in_space ~prefix:shares_prefix "bb") ()
     in
     let m = Yojson.Basic.from_string (Bigstring.to_string body) in
     assert (member "type" m = `String "dir");
     assert (member "filename" m = `String "testdom.zip");
     assert (
       member "dirPrefix" m
       = `String (C.domain_prefix ^ Stored_key.root_id ^ "/"));
     Lwt.return_unit);

  let module NoShare : Backend.S = struct
    include
      (val Backend.make ~backend_type:"local"
             ~get_field:(fun _ -> Some store_dir)
             ()
          : Backend.S)
  end in
  let module C2 : Conf.S = struct
    include C

    let store = (module NoShare : Backend.S)
    let members = [Backend.member ~name:"local" store]
  end in
  let module S2 = Share.Make (C2) in
  (match Lwt_main.run (S2.create ~expires:123 ~rel:"foo" ()) with
    | Error _ -> ()
    | Ok _ -> assert false);

  (* A domain whose every backend is [readOnly]: nothing writable, the store
     reachable only as a fallback. Sharing still has to work, a share manifest
     living outside every domain root — which is why it goes to a member
     directly rather than through the write composite. *)
  let module ReadOnlyDomain : Conf.S = struct
    include C

    let store =
      Domain_store.make ~mains:[] ~targets:[]
        ~archives:
          [{ Domain_store.name = "archive"; backend = (module Shareable) }]

    let members =
      [Backend.member ~name:"archive" ~role:`ReadOnly (module Shareable)]
  end in
  let module S3 = Share.Make (ReadOnlyDomain) in
  (* The composite really does refuse writes: without that, this proves nothing. *)
  let (module Composite : Backend.S) = ReadOnlyDomain.store in
  (match
     Lwt_main.run
       (Composite.put
          ~key:(Stored_key.listed "tsync/shares/zz")
          ~data:(Bigstring.of_string "x") ())
   with
    | exception Backend.Not_writable -> ()
    | _ -> assert false);
  (match Lwt_main.run (S3.create ~token:"cc" ~expires:123 ~rel:"foo" ()) with
    | Ok u -> assert (u = share_base ^ "/cc")
    | Error e -> failwith e);

  (* Only the backfill target serves shares, and reads never reach it: it is
     the last choice, not a skipped one. *)
  let module BackfillOnly : Conf.S = struct
    include C

    let members =
      [
        Backend.member ~name:"local" (module NoShare);
        Backend.member ~name:"gcs" ~role:`Backfill ~readable:false
          (module Shareable);
      ]
  end in
  let module S4 = Share.Make (BackfillOnly) in
  (match Lwt_main.run (S4.create ~token:"dd" ~expires:123 ~rel:"foo" ()) with
    | Ok u -> assert (u = share_base ^ "/dd")
    | Error e -> failwith e);

  (match Lwt_main.run (S3.create ~expires:123 ~rel:"no/such/dir" ()) with
    | Error e -> assert (String.length e >= 9 && String.sub e 0 9 = "not found")
    | Ok _ -> assert false);

  (* Clearing the cache takes the assembled artifacts — the ones under cache/,
     and the loose .data siblings written before that subtree existed — and
     leaves every published manifest where it is. *)
  let (module B : Backend.S) = (module Shareable) in
  Lwt_main.run
    (let open Lwt.Syntax in
     let cached =
       [
         shares_prefix ^ "cache/aa.data";
         shares_prefix ^ "cache/1111111111111111-2222222222222222.data";
         shares_prefix ^ "cache/compose-tmp/deadbeef-0";
         shares_prefix ^ "3333333333333333-4444444444444444.data";
       ]
     in
     let* () =
       Lwt_list.iter_s
         (fun key ->
           B.put ~key:(Stored_key.listed key)
             ~data:(Bigstring.of_string "1234")
             ())
         cached
     in
     let* result = S.clear_cache () in
     let n, bytes = match result with Ok v -> v | Error e -> failwith e in
     assert (n = List.length cached);
     assert (bytes = 4 * List.length cached);
     let* left = B.list_prefix ~prefix:shares_prefix () in
     (* A filesystem backend lists the directories a delete left behind; an
        object store has none. *)
     let left =
       List.sort compare
         (List.filter_map
            (fun (e : Backend.file_entry) ->
              if Stored_key.is_dir_key e.key then None else Some e.key)
            left)
     in
     (* The tokens published above, and nothing else. *)
     assert (
       left
       = List.map
           (fun t -> Stored_key.in_space ~prefix:shares_prefix t)
           ["aa"; "bb"; "cc"; "dd"]);
     (* Idempotent: a second pass has nothing to take. *)
     let+ again = S.clear_cache () in
     assert (again = Ok (0, 0)));

  print_endline "share_test: OK"
