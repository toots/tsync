open Lwt.Syntax

(* Two, because they mean different things: nothing here can serve a link at all,
   versus there is nothing at that path to link to. Raised internally and mapped
   to [Error] at the boundary, so callers decide how to report. *)
exception Share_unavailable of string
exception Share_not_found of string

module Make (C : Conf.S) = struct
  module L = Layout.Inode.Make (C)
  module Bks = Backends.Make (C)

  let shares_prefix = C.shares_prefix

  (* Asked of the individual stores, not the read/write composite: a share
     manifest lives outside every domain root, so a domain with nothing writable
     can still publish one. *)
  let share_backend () =
    let rec find = function
      | [] ->
          Lwt.fail
            (Share_unavailable
               (Printf.sprintf "Sharing is not available for %s." C.domain_name))
      | (module Bk : Backend.S) :: rest -> (
          let* u = Bk.share_url ~prefix:C.domain_prefix () in
          match u with
            | Some url -> Lwt.return ((module Bk : Backend.S), url)
            | None -> find rest)
    in
    find C.share_backends

  (* Build the manifest for [rel] ("" = whole domain), PUT it under a token, and
     return the download URL. *)
  let create ?token ~expires ~rel () =
    Lwt.catch
      (fun () ->
        let* share_backend, share_url = share_backend () in
        let (module B : Backend.S) = share_backend in
        (* Read through the domain's own read path; the store serving the link
           is chosen for where the link points, not for holding the newest
           copy. *)
        let (module R : Backend.S) = Bks.primary () in
        let base_json = [("v", `Int 1); ("expires", `Int expires)] in
        let* manifest =
          let* file_key = L.manifest_key (C.domain_prefix ^ rel) in
          (* A file manifest and a folder marker occupy the same key within a
             parent namespace, so classification is by body: otherwise a folder is
             shared as a chunkless file and the Lambda chokes. *)
          (* Sharing is a read: an unresolvable key is the same answer as an
             absent object. *)
          let* obj =
            match file_key with
              | Some file_key when rel <> "" -> R.get_opt ~key:file_key ()
              | _ -> Lwt.return_none
          in
          let marker = Option.bind obj Folder.marker_of_string in
          match (file_key, obj, marker) with
            | Some file_key, Some _, None ->
                (* Single file: the Lambda fetches the manifest by this key. *)
                Lwt.return
                  (`Assoc
                     (base_json
                     @ [
                         ("type", `String "file");
                         ("key", `String file_key);
                         ("chunkPrefix", `String C.chunk_prefix);
                         ("filename", `String (Filename.basename rel));
                       ]))
            | _ ->
                (* Directory: store the folder's namespace prefix by id and let
                   the Lambda list it lazily, keeping creation O(1). *)
                (* Never mint here: no marker means the folder does not exist
                   remotely, so a fresh id names a namespace nothing wrote to, and
                   persisting it re-creates the local directory on a read. *)
                let* dir_id =
                  match marker with
                    | Some m -> Lwt.return_some m.Folder.id
                    | None ->
                        Folder_ids.lookup_id ~cache_root:C.cache_root
                          ~domain_name:C.domain_name rel
                in
                let* dir_prefix =
                  match dir_id with
                    | Some id -> Lwt.return (C.domain_prefix ^ id ^ "/")
                    | None ->
                        Lwt.fail
                          (Share_not_found (Printf.sprintf "not found: %s" rel))
                in
                let* entries =
                  R.list_prefix ~prefix:dir_prefix ~max_keys:1 ()
                in
                if entries = [] then
                  Lwt.fail
                    (Share_not_found (Printf.sprintf "not found: %s" rel))
                else (
                  let base =
                    if rel = "" then C.domain_name else Filename.basename rel
                  in
                  Lwt.return
                    (`Assoc
                       (base_json
                       @ [
                           ("type", `String "dir");
                           ("chunkPrefix", `String C.chunk_prefix);
                           ("dirPrefix", `String dir_prefix);
                           ("filename", `String (base ^ ".zip"));
                         ])))
        in
        (* The token is the manifest's id and the server rebuilds the key as
           SHARES_PREFIX + token, keeping the URL short. A caller-supplied id
           gives a stable link. *)
        let token = Option.value token ~default:(Id.token 16) in
        let manifest_key = shares_prefix ^ token in
        let* () =
          B.put ~key:manifest_key ~data:(Yojson.Basic.to_string manifest) ()
        in
        Lwt.return_ok (share_url ^ "/" ^ token))
      (function
        | Share_unavailable msg | Share_not_found msg -> Lwt.return_error msg
        | exn -> Lwt.fail exn)
end
