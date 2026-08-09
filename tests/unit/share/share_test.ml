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
    (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some store_dir)
        : Backend.S)

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
  let cursor_key = "tsync/testdom/cursor"
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
     let* file_key = L.ensure_manifest_key (C.domain_prefix ^ "foo") in
     let* () = B.put ~key:file_key ~data:"{\"chunks\":[]}" () in
     let* url = S.create ~token:"aa" ~expires:123 ~rel:"foo" () in
     let url = match url with Ok u -> u | Error e -> failwith e in
     assert (url = share_base ^ "/aa");
     let* body = B.get ~key:(shares_prefix ^ "aa") () in
     let m = Yojson.Basic.from_string body in
     assert (member "type" m = `String "file");
     assert (member "key" m = `String file_key);
     assert (member "filename" m = `String "foo");
     assert (member "expires" m = `Int 123);

     let* () =
       B.put ~key:(C.domain_prefix ^ Folder.root_id ^ "/x") ~data:"x" ()
     in
     let* url = S.create ~token:"bb" ~expires:123 ~rel:"" () in
     let url = match url with Ok u -> u | Error e -> failwith e in
     assert (url = share_base ^ "/bb");
     let* body = B.get ~key:(shares_prefix ^ "bb") () in
     let m = Yojson.Basic.from_string body in
     assert (member "type" m = `String "dir");
     assert (member "filename" m = `String "testdom.zip");
     assert (
       member "dirPrefix" m = `String (C.domain_prefix ^ Folder.root_id ^ "/"));
     Lwt.return_unit);

  let module NoShare : Backend.S = struct
    include
      (val Backend.make ~backend_type:"local" ~get_field:(fun _ ->
               Some store_dir)
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
      [Backend.member ~name:"archive" ~role:"readOnly" (module Shareable)]
  end in
  let module S3 = Share.Make (ReadOnlyDomain) in
  (* The composite really does refuse writes: without that, this proves nothing. *)
  let (module Composite : Backend.S) = ReadOnlyDomain.store in
  (match Lwt_main.run (Composite.put ~key:"tsync/shares/zz" ~data:"x" ()) with
    | exception Backend.Not_writable -> ()
    | _ -> assert false);
  (match Lwt_main.run (S3.create ~token:"cc" ~expires:123 ~rel:"foo" ()) with
    | Ok u -> assert (u = share_base ^ "/cc")
    | Error e -> failwith e);

  (match Lwt_main.run (S3.create ~expires:123 ~rel:"no/such/dir" ()) with
    | Error e -> assert (String.length e >= 9 && String.sub e 0 9 = "not found")
    | Ok _ -> assert false);

  print_endline "share_test: OK"
