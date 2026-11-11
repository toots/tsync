open Tsync_core
open Tsync_store
open Tsync_remote

type created = { url : string; expires : float }

let default_expiry = 7. *. 86400.
let site_grace = 2. *. 86400.

(* 05 §4.11: one GET that follows no redirect; its status, or the failure. *)
let ask link =
  match
    Tsync_http.Client.request ~stall:30.
      (Tsync_http.Client.endpoint ~max_connections:1 link)
      ~meth:"GET" ""
  with
    | r -> Ok r.status
    | exception Fail.E f -> Error f.reason

let index_pages = ["index.html"; "index.htm"]

(* 05 §4.11: asked once after a site share is created, so its copy is
   published before the first visitor. *)
let publish link =
  match ask link with
    | Ok 302 -> ()
    | Ok status ->
        Log.debug "share: publishing a site: the link answered %d" status
    | Error why -> Log.debug "share: publishing a site: %s" why

(* security §6.1: what a creator writes, generated or chosen. *)
let creatable t =
  let n = String.length t in
  n >= 32 && n <= 128 && String.for_all Names.is_hexlower t

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain
  let name = Domain_name.to_string d

  let chosen ?member () =
    let m, url = Composite.share_member ?name:member C.composite in
    Composite.guard C.composite m "share";
    (m, url)

  let segs p = if p = "" then [] else String.split_on_char '/' p

  let body ~expires ~target ~filename ~site =
    Yojson.Safe.to_string
      (`Assoc
         ([
            ("v", `Int 1);
            ("expires", `Int (int_of_float expires));
            ("domain", `String name);
          ]
         @ target
         @ [("filename", `String filename)]
         @ if site then [("site", `Bool true)] else []))

  (* http-proxy §A9.9: the link opens the folder's index page. *)
  let has_index id =
    List.exists
      (fun (e : Tree.entry) ->
        match e.body with
          | File m -> List.mem m.name index_pages
          | Dir _ -> false)
      (T.children id)

  let create ?(expires = default_expiry) ?token ?member ?(site = false) rel =
    if not (expires > 0. && Float.is_finite expires) then
      Fail.raise_ Fail.Invalid "a share's lifetime must be finite and positive";
    let m, url = chosen ?member () in
    let target, filename, present =
      match T.find Folder_id.root (segs rel) with
        | `Missing ->
            Fail.raise_ Fail.Absent "%s: no such file or folder in %s" rel name
        | `File _ when site ->
            Fail.raise_ Fail.Absent "%s: only a folder can be shared as a site"
              rel
        | `File manifest ->
            let parent =
              match T.find Folder_id.root (segs (Names.parent_of rel)) with
                | `Folder id -> id
                | _ -> Fail.raise_ Fail.Absent "%s: no such file in %s" rel name
            in
            let key = Key.child d parent (Names.leaf_of rel) in
            ( [("type", `String "file"); ("key", `String (Key.to_string key))],
              (if rel = "" then manifest.name else Names.leaf_of rel),
              m.store.head_opt key <> None )
        | `Folder id ->
            if T.children id = [] then
              Fail.raise_ Fail.Absent "%s: an empty folder has nothing to share"
                rel;
            if site && not (has_index id) then
              Fail.raise_ Fail.Absent "%s has no index.html"
                (if rel = "" then "/" else rel);
            ( [
                ("type", `String "dir");
                ("folderId", `String (Folder_id.to_string id));
              ],
              (if rel = "" then name else Names.leaf_of rel) ^ ".zip",
              m.store.list_prefix ~max_keys:1 (Key.namespace d id) <> [] )
    in
    if not present then
      Fail.raise_ Fail.Refused "%s is not on %s yet"
        (if rel = "" then "/" else rel)
        m.name;
    let expires = Float.round (Unix.gettimeofday () +. expires) in
    let manifest = body ~expires ~target ~filename ~site in
    let token =
      match token with
        | None ->
            let token = Ids.token () in
            m.store.put
              (Option.get (Key.share token))
              (Bigstring.of_string manifest);
            token
        | Some t when not (creatable t) ->
            Fail.raise_ Fail.Invalid
              "a token is 32 to 128 lowercase hex characters"
        | Some t -> (
            match
              m.store.put_if_absent
                (Option.get (Key.share t))
                (Bigstring.of_string manifest)
            with
              | Won -> t
              | Held b when Bigstring.to_string b = manifest -> t
              | Held _ -> Fail.raise_ Fail.Exists "the token %s is taken" t)
    in
    let url = if String.ends_with ~suffix:"/" url then url else url ^ "/" in
    { url = url ^ token; expires }

  let token_of s =
    match String.rindex_opt s '/' with
      | Some i -> String.sub s (i + 1) (String.length s - i - 1)
      | None -> s

  let names_domain body =
    match Yojson.Safe.from_string (Bigstring.to_string body) with
      | `Assoc f -> List.assoc_opt "domain" f = Some (`String name)
      | _ | (exception Yojson.Json_error _) -> false

  let site_expiry body =
    match Yojson.Safe.from_string (Bigstring.to_string body) with
      | `Assoc f when List.assoc_opt "site" f = Some (`Bool true) -> (
          match List.assoc_opt "expires" f with
            | Some (`Int n) -> Some (float_of_int n)
            | Some (`Float x) -> Some x
            | _ -> Some 0.)
      | _ | (exception Yojson.Json_error _) -> None

  (* security §6.5: the share server removes the published copy once it finds
     the share gone, which only asking the link tells it. *)
  let unpublish (m : Composite.member) token expires =
    let link =
      Option.map
        (fun url ->
          (if String.ends_with ~suffix:"/" url then url else url ^ "/") ^ token)
        (m.store.capabilities Key.shares).share_url
    in
    match Option.map ask link with
      | Some (Ok (404 | 410)) -> ()
      | answer ->
          Log.info "share: unpublishing a site: %s"
            (match answer with
              | Some (Ok status) -> Printf.sprintf "the link answered %d" status
              | Some (Error why) -> why
              | None -> m.name ^ " serves no share links");
          Fail.raise_ Fail.Refused
            "the link is revoked, but its published site stays readable until \
             %s"
            (Narrate.date (expires +. site_grace))

  let revoke s =
    let token = token_of s in
    match Key.share token with
      | None -> Fail.raise_ Fail.Invalid "%s is not a share token or link" s
      | Some key ->
          let unpublished = ref [] in
          let found =
            List.fold_left
              (fun found (m : Composite.member) ->
                match m.store.get_opt key with
                  | Some b when names_domain b ->
                      Composite.guard C.composite m "revoke a share";
                      ignore (m.store.delete key);
                      Option.iter
                        (fun expires ->
                          match unpublish m token expires with
                            | () -> ()
                            | exception Fail.E f ->
                                unpublished := f :: !unpublished)
                        (site_expiry b);
                      ignore
                        (m.store.delete (Option.get (Key.share_site token)));
                      ignore
                        (m.store.delete
                           (Key.v
                              (Key.prefix_to_string Key.share_cache
                              ^ token ^ ".data")));
                      ignore
                        (m.store.delete (Option.get (Key.share_preview token)));
                      true
                  | _ -> found)
              false
              (Composite.members C.composite)
          in
          (match !unpublished with f :: _ -> raise (Fail.E f) | [] -> ());
          found

  let field f k =
    match List.assoc_opt k f with Some (`String s) -> Some s | _ -> None

  (* 05 §4.11: made through the link itself, then written beside the manifest,
     replacing any. *)
  let preview s =
    let token = token_of s in
    let key =
      match Key.share token with
        | Some k -> k
        | None -> Fail.raise_ Fail.Invalid "%s is not a share token or link" s
    in
    let held =
      List.find_map
        (fun (m : Composite.member) ->
          match Option.map Bigstring.to_string (m.store.get_opt key) with
            | Some b
              when Gc_plan.share ~domain:d ~now:(Unix.gettimeofday ()) b = Kept
              -> (
                match Yojson.Safe.from_string b with
                  | `Assoc f -> Some (m, f)
                  | _ | (exception Yojson.Json_error _) -> None)
            | _ -> None)
        (Composite.members C.composite)
    in
    match held with
      | None ->
          Fail.raise_ Fail.Absent "no live share of %s has the token %s" name
            token
      | Some (m, f) -> (
          let filename = Option.value ~default:"" (field f "filename") in
          match
            ( field f "type",
              Share_preview.kind_of_name filename,
              (m.store.capabilities Key.shares).share_url )
          with
            | Some "file", Some kind, Some url ->
                if not (Share_preview.available ()) then
                  `Not_made "this build cannot make preview images"
                else (
                  let url =
                    if String.ends_with ~suffix:"/" url then url else url ^ "/"
                  in
                  match Share_preview.make ~kind (url ^ token ^ "/f") with
                    | None -> `Not_made ("no image could be made of " ^ filename)
                    | Some b ->
                        Composite.guard C.composite m "store a share preview";
                        let image = Option.get (Key.share_preview token) in
                        m.store.put image b;
                        (* A revoke during the decode deleted the image before
                           it was written. *)
                        if m.store.get_opt key = None then (
                          ignore (m.store.delete image);
                          `Not_made "the share was revoked")
                        else `Made)
            | Some "file", _, Some _ ->
                `Not_made
                  (filename ^ " is not an image, a video or an audio file")
            | _, _, None -> `Not_made (m.name ^ " serves no share links")
            | _ -> `Not_made "a folder share has no preview image")

  (* 05 §4.11: the share cache, and anything in the share space that is not a
     share manifest. *)
  let clear_cache () =
    List.fold_left
      (fun (n, bytes) (m : Composite.member) ->
        if m.role = Read_only then (n, bytes)
        else (
          let doomed =
            List.filter
              (fun (e : Store.entry) ->
                Key.under Key.share_cache e.key
                ||
                  match Key.share (Key.leaf e.key) with
                  | Some k -> not (Key.equal k e.key)
                  | None -> true)
              (m.store.list_prefix Key.shares)
          in
          if doomed = [] then (n, bytes)
          else (
            Composite.guard C.composite m "clear the share cache";
            m.store.delete_multi
              (List.map (fun (e : Store.entry) -> e.key) doomed);
            ( n + List.length doomed,
              bytes
              + List.fold_left (fun a (e : Store.entry) -> a + e.size) 0 doomed
            ))))
      (0, 0)
      (Composite.members C.composite)
end
