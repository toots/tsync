type backend_config = {
  backend_type : string;
  name : string;
  fields : (string * string) list;
  main : bool;
}

type domain = {
  name : string;
  prefix : string;
  backends : backend_config list;
  symlink_policy : [ `Keep | `Follow | `Skip ];
  versioning : bool;
  read_only : bool;
}

type t = {
  name : string;
  tls : string option;
  max_uploads : int;
  max_downloads : int;
  domains : domain list;
}

let default_max_uploads = 4
let default_max_downloads = 8

let parse_backend json =
  let open Yojson.Basic.Util in
  let backend_type = json |> member "type" |> to_string in
  let name =
    match json |> member "name" with
      | `String s -> s
      | _ ->
          failwith
            ("backend config missing required \"name\" field (type: "
           ^ backend_type ^ ")")
  in
  let main = match json |> member "main" with `Bool b -> b | _ -> false in
  let fields =
    to_assoc json
    |> List.filter_map (fun (k, v) ->
        if k = "type" || k = "main" || k = "name" then None
        else (
          match v with
            | `String s -> Some (k, s)
            | `Bool b -> Some (k, string_of_bool b)
            (* Array fields (e.g. exec backend "command") pass through as JSON
               for the backend factory to decode. *)
            | `List _ -> Some (k, Yojson.Basic.to_string v)
            | _ -> None))
  in
  { backend_type; name; fields; main }

(* The primary backend serves reads; writes still fan out to all. Pick the first
   one explicitly marked [main], else the first local-file backend (local disk
   is faster and more available than the cloud), else the first configured. *)
let primary_backend backends =
  match List.find_opt (fun b -> b.main) backends with
    | Some _ as b -> b
    | None -> (
        match List.find_opt (fun b -> b.backend_type = "local") backends with
          | Some _ as b -> b
          | None -> ( match backends with b :: _ -> Some b | [] -> None))

(* Return the backends with the primary moved to the front (others keep their
   order), so [List.hd] / [b :: _] downstream select the primary. *)
let order_backends backends =
  match primary_backend backends with
    | None -> backends
    | Some primary -> primary :: List.filter (fun b -> b != primary) backends

let parse_symlink_policy json =
  let open Yojson.Basic.Util in
  match json |> member "symlinks" with
    | `String "keep" -> `Keep
    | `String "follow" -> `Follow
    | `String "skip" -> `Skip
    | `String s -> failwith ("unknown symlinks policy: " ^ s)
    | `Null -> failwith "domain config missing required \"symlinks\" field"
    | _ -> failwith "domain \"symlinks\" field must be a string"

let parse_domain json =
  let open Yojson.Basic.Util in
  {
    name = json |> member "name" |> to_string;
    prefix = json |> member "prefix" |> to_string;
    backends = json |> member "backends" |> to_list |> List.map parse_backend;
    symlink_policy = parse_symlink_policy json;
    versioning = json |> member "versioning" |> to_bool;
    read_only =
      (match json |> member "readOnly" with `Bool b -> b | _ -> false);
  }

let load path =
  let json =
    match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some s -> Yojson.Basic.from_string s
      | None -> Yojson.Basic.from_file path
  in
  let open Yojson.Basic.Util in
  {
    name =
      (match json |> member "name" with
        | `String s -> s
        | _ -> Unix.gethostname ());
    tls = (match json |> member "tls" with `String s -> Some s | _ -> None);
    max_uploads =
      (match json |> member "maxUploads" with
        | `Int n when n > 0 -> n
        | _ -> default_max_uploads);
    max_downloads =
      (match json |> member "maxDownloads" with
        | `Int n when n > 0 -> n
        | _ -> default_max_downloads);
    domains = json |> member "domains" |> to_list |> List.map parse_domain;
  }

let pick_domain ?domain cfg =
  match domain with
    | Some name -> (
        match List.find_opt (fun (d : domain) -> d.name = name) cfg.domains with
          | Some d -> d
          | None -> failwith ("domain not found: " ^ name))
    | None -> (
        match cfg.domains with
          | [d] -> d
          | [] -> failwith "no domains configured"
          | _ -> failwith "multiple domains configured — use --domain to select"
        )

let prefix_slash d =
  let p = d.prefix in
  if p = "" then "" else if p.[String.length p - 1] = '/' then p else p ^ "/"

let domain_prefix d = prefix_slash d ^ d.name ^ "/"
let chunk_prefix d = prefix_slash d ^ ".chunks/"
let versions_prefix d = prefix_slash d ^ ".versions/" ^ d.name ^ "/"
let journal_prefix d = prefix_slash d ^ ".journal/" ^ d.name ^ "/"
let cursor_key d = prefix_slash d ^ ".cursor/" ^ d.name
