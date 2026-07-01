type backend_config = { backend_type : string; fields : (string * string) list }
type domain = { name : string; prefix : string; backends : backend_config list }
type t = { versioning : bool; domains : domain list }

let parse_backend json =
  let open Yojson.Basic.Util in
  let backend_type = json |> member "type" |> to_string in
  let fields =
    to_assoc json
    |> List.filter_map (fun (k, v) ->
        if k = "type" then None
        else (match v with `String s -> Some (k, s) | _ -> None))
  in
  { backend_type; fields }

let parse_domain json =
  let open Yojson.Basic.Util in
  {
    name = json |> member "name" |> to_string;
    prefix = json |> member "prefix" |> to_string;
    backends = json |> member "backends" |> to_list |> List.map parse_backend;
  }

let load path =
  let json =
    match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some s -> Yojson.Basic.from_string s
      | None -> Yojson.Basic.from_file path
  in
  let open Yojson.Basic.Util in
  {
    versioning = json |> member "versioning" |> to_bool;
    domains = json |> member "domains" |> to_list |> List.map parse_domain;
  }

let pick_domain ?domain cfg =
  match domain with
    | Some name -> (
        match List.find_opt (fun d -> d.name = name) cfg.domains with
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
let trash_prefix d = prefix_slash d ^ ".trash/" ^ d.name ^ "/"
let journal_prefix d = prefix_slash d ^ ".journal/" ^ d.name ^ "/"
let version_key d = prefix_slash d ^ ".version/" ^ d.name
