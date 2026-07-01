type t = {
  bucket : string;
  prefix : string;
  aws_region : string;
  versioning : bool;
  access_key_id : string;
  secret_access_key : string;
  domain_name : string;
}

let load path =
  let json =
    match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some s -> Yojson.Basic.from_string s
      | None -> Yojson.Basic.from_file path
  in
  let open Yojson.Basic.Util in
  {
    bucket = json |> member "bucket" |> to_string;
    prefix = json |> member "prefix" |> to_string;
    aws_region = json |> member "awsRegion" |> to_string;
    versioning = json |> member "versioning" |> to_bool;
    access_key_id = json |> member "accessKeyId" |> to_string;
    secret_access_key = json |> member "secretAccessKey" |> to_string;
    domain_name = json |> member "domainName" |> to_string;
  }

let prefix_slash cfg =
  let p = cfg.prefix in
  if String.length p > 0 && p.[String.length p - 1] = '/' then p else p ^ "/"

let domain_prefix cfg domain_name = prefix_slash cfg ^ domain_name ^ "/"
let chunk_prefix cfg = prefix_slash cfg ^ ".chunks/"
let trash_prefix cfg domain_name = prefix_slash cfg ^ ".trash/" ^ domain_name ^ "/"
let journal_prefix cfg domain_name = prefix_slash cfg ^ ".journal/" ^ domain_name ^ "/"
let version_key cfg domain_name = prefix_slash cfg ^ ".version/" ^ domain_name
