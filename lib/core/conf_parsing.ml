type backend_config = {
  backend_type : string;
  name : string;
  fields : (string * string) list;
  main : bool;
}

type frontend_config = {
  frontend_type : string;
  options : (string * string) list;
}

type domain = {
  name : string;
  backends : backend_config list;
  frontends : frontend_config list;
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

(* A frontend is either a bare type name ["fuse"] or an object
   [{"type": "fuse", ...options}]; the string form is shorthand for an object
   with no options. Extra keys are kept as string fields for future options. *)
let parse_frontend json =
  let open Yojson.Basic.Util in
  match json with
    | `String frontend_type -> { frontend_type; options = [] }
    | `Assoc _ ->
        let frontend_type = json |> member "type" |> to_string in
        let options =
          to_assoc json
          |> List.filter_map (fun (k, v) ->
              if k = "type" then None
              else (
                match v with
                  | `String s -> Some (k, s)
                  | `Bool b -> Some (k, string_of_bool b)
                  | `List _ -> Some (k, Yojson.Basic.to_string v)
                  | _ -> None))
        in
        { frontend_type; options }
    | _ ->
        failwith
          "frontend must be a type name or an object with a \"type\" field"

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
    backends = json |> member "backends" |> to_list |> List.map parse_backend;
    frontends =
      (match json |> member "frontends" with
        | `List (_ :: _ as l) -> List.map parse_frontend l
        | _ ->
            failwith
              "domain config missing required non-empty \"frontends\" array");
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

let root_prefix = "tsync/"

(* Everything for a domain lives under one folder so a domain can be dropped with
   a single prefix delete. Chunks are per-domain (no cross-domain dedup). *)
let domain_root (d : domain) = root_prefix ^ d.name ^ "/"
let domain_prefix d = domain_root d ^ "manifests/"
let chunk_prefix d = domain_root d ^ "chunks/"
let versions_prefix d = domain_root d ^ "versions/"
let journal_prefix d = domain_root d ^ "journal/"
let cursor_key d = domain_root d ^ "cursor"
let shares_prefix d = domain_root d ^ "shares/"

(* A backend's share Lambda URL, if it has a non-empty [shareUrl] field. *)
let backend_share_url bc =
  match List.assoc_opt "shareUrl" bc.fields with
    | Some u when u <> "" -> Some u
    | _ -> None

(* The first backend (in config order) that carries a [shareUrl], with its URL.
   This backend both serves the domain's shares and receives the share
   manifests. *)
let domain_share_backend d =
  List.find_map
    (fun bc -> Option.map (fun u -> (bc, u)) (backend_share_url bc))
    d.backends
