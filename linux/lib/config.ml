type domain = { name : string }

type t = {
  bucket : string;
  prefix : string;
  aws_region : string;
  versioning : bool;
  access_key_id : string;
  secret_access_key : string;
  domains : domain list;
}

let config_path () =
  let xdg =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
      | Some d -> d
      | None -> Filename.concat (Sys.getenv "HOME") ".config"
  in
  Filename.concat xdg "tsync/config.json"

let load () =
  let json =
    match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some s -> Yojson.Basic.from_string s
      | None -> Yojson.Basic.from_file (config_path ())
  in
  (* Credentials may be inline or in a sibling credentials.json (macOS compat) *)
  let open Yojson.Basic.Util in
  let creds_json =
    match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some _ -> json (* credentials are already merged in *)
      | None ->
          let creds_path =
            Filename.concat
              (Filename.dirname (config_path ()))
              "credentials.json"
          in
          if Sys.file_exists creds_path then Yojson.Basic.from_file creds_path
          else json
  in
  {
    bucket = json |> member "bucket" |> to_string;
    prefix = json |> member "prefix" |> to_string;
    aws_region = json |> member "awsRegion" |> to_string;
    versioning = json |> member "versioning" |> to_bool;
    access_key_id = creds_json |> member "accessKeyId" |> to_string;
    secret_access_key = creds_json |> member "secretAccessKey" |> to_string;
    domains =
      json |> member "domains" |> to_list
      |> List.map (fun d -> { name = d |> member "name" |> to_string });
  }

let save cfg =
  let path = config_path () in
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let domains_json =
    `List (List.map (fun d -> `Assoc [("name", `String d.name)]) cfg.domains)
  in
  let json =
    `Assoc
      [
        ("bucket", `String cfg.bucket);
        ("prefix", `String cfg.prefix);
        ("awsRegion", `String cfg.aws_region);
        ("versioning", `Bool cfg.versioning);
        ("accessKeyId", `String cfg.access_key_id);
        ("secretAccessKey", `String cfg.secret_access_key);
        ("domains", domains_json);
      ]
  in
  let oc = open_out path in
  Yojson.Basic.pretty_to_channel oc json;
  close_out oc

let domain_prefix cfg domain_name =
  let p = cfg.prefix in
  let p =
    if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"
  in
  p ^ domain_name ^ "/"

let chunk_prefix cfg =
  let p = cfg.prefix in
  let p =
    if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"
  in
  p ^ ".chunks/"

let trash_prefix cfg domain_name =
  let p = cfg.prefix in
  let p =
    if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"
  in
  p ^ ".trash/" ^ domain_name ^ "/"

let journal_prefix cfg domain_name =
  let p = cfg.prefix in
  let p =
    if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"
  in
  p ^ ".journal/" ^ domain_name ^ "/"

let version_key cfg domain_name =
  let p = cfg.prefix in
  let p =
    if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"
  in
  p ^ ".version/" ^ domain_name
