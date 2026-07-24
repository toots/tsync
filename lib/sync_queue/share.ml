open Lwt.Syntax

(* Errors surfaced to the caller (missing share backend, unknown path). Raised
   internally and mapped to [Error] at the boundary so callers decide how to
   report — the CLI prints and exits, the daemon returns an IPC error. *)
exception Share_error of string

let random_hex bytes =
  let b = Bytes.create bytes in
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input ic b 0 bytes);
  String.concat ""
    (List.init bytes (fun i ->
         Printf.sprintf "%02x" (Char.code (Bytes.get b i))))

module Make (C : Conf.S) = struct
  module L = Layout.Inode.Make (C)

  (* [C.domain_prefix] is [domain_root ^ "manifests/"]; shares live alongside at
     [domain_root ^ "shares/"]. *)
  let shares_prefix =
    let suffix = "manifests/" in
    let n = String.length C.domain_prefix and s = String.length suffix in
    if n >= s && String.sub C.domain_prefix (n - s) s = suffix then
      String.sub C.domain_prefix 0 (n - s) ^ "shares/"
    else C.domain_prefix ^ "shares/"

  (* First backend whose [share_url] serves this domain (an s3 with a shareUrl,
     or an http-proxy that reports one). *)
  let share_backend () =
    let rec find = function
      | [] ->
          Lwt.fail
            (Share_error
               (Printf.sprintf "no backend in domain %s serves shares"
                  C.domain_name))
      | (module Bk : Backend.S) :: rest -> (
          let* u = Bk.share_url ~prefix:C.domain_prefix () in
          match u with
            | Some url -> Lwt.return ((module Bk : Backend.S), url)
            | None -> find rest)
    in
    find C.backends

  (* Build the manifest for [rel] ("" = whole domain), PUT it under a token, and
     return the download URL. *)
  let create ?token ~expires ~rel () =
    Lwt.catch
      (fun () ->
        let* share_backend, share_url = share_backend () in
        let (module B : Backend.S) = share_backend in
        let base_json = [("v", `Int 1); ("expires", `Int expires)] in
        let* manifest =
          let* file_key = L.manifest_key (C.domain_prefix ^ rel) in
          (* A file manifest and a folder marker occupy the same key within a
             parent namespace, so classify by the body — otherwise a folder
             would be shared as a (chunkless) file and the Lambda would choke. *)
          let* obj =
            if rel = "" then Lwt.return_none else B.get_opt ~key:file_key ()
          in
          let marker = Option.bind obj Folder.marker_of_string in
          match (obj, marker) with
            | Some _, None ->
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
                (* Directory (a folder marker, or the domain root): store the
                   folder's namespace prefix (by id); the Lambda lists it lazily.
                   Keeps share creation O(1). *)
                let* dir_id =
                  match marker with
                    | Some m -> Lwt.return m.Folder.id
                    | None ->
                        Folder_ids.resolve ~cache_root:C.cache_root
                          ~domain_name:C.domain_name rel
                in
                let dir_prefix = C.domain_prefix ^ dir_id ^ "/" in
                let* entries = B.list_all ~prefix:dir_prefix ~max_keys:1 () in
                if entries = [] then
                  Lwt.fail (Share_error (Printf.sprintf "not found: %s" rel))
                else
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
                         ]))
        in
        (* The token is just the manifest's id; the server rebuilds the key as
           SHARES_PREFIX + token. Keeps the share URL short. Reuse a caller-
           supplied id (stable links) or generate a random one. *)
        let token = Option.value token ~default:(random_hex 16) in
        let manifest_key = shares_prefix ^ token in
        let* () =
          B.put ~key:manifest_key ~data:(Yojson.Basic.to_string manifest) ()
        in
        Lwt.return_ok (share_url ^ "/" ^ token))
      (function
        | Share_error msg -> Lwt.return_error msg
        | exn -> Lwt.fail exn)
end
