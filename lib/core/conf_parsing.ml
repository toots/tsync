type backend_config = {
  backend_type : string;
  name : string;
  fields : (string * string) list;
  main : bool;
  backfill : bool;
  read_only : bool;
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
  chunk_size : int option;
  cache_chunk_size : int option;
  max_cache : int option;
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

(* Per-domain, overridable via "chunkSize". 8 MiB favors sequential throughput
   and small manifests; lower it for random-access workloads to cut read/write
   amplification (at the cost of larger manifests and more backend requests). *)
let default_chunk_size = 8 * 1024 * 1024

(* Per-domain, overridable via "cacheChunkSize". The local cache stores
   consecutive stored chunks grouped into files of about this size: storage
   granularity wants to be small (less egress when a file changes), disk
   granularity wants to be large (fewer opens, less I/O latency), so the two are
   configured apart. Absent, it follows "chunkSize" and no grouping happens; this
   is only the value [tsync configure] proposes. *)
let default_cache_chunk_size = 64 * 1024 * 1024

(* Human-friendly byte sizes: a bare number is bytes; a K/M/G suffix (with an
   optional B/iB) is a binary multiple (1K = 1024). *)
let format_size b =
  let k = 1024 and m = 1024 * 1024 and g = 1024 * 1024 * 1024 in
  if b >= g && b mod g = 0 then Printf.sprintf "%dG" (b / g)
  else if b >= m && b mod m = 0 then Printf.sprintf "%dM" (b / m)
  else if b >= k && b mod k = 0 then Printf.sprintf "%dK" (b / k)
  else string_of_int b

let parse_size s =
  let s = String.trim (String.lowercase_ascii s) in
  if s = "" then None
  else (
    let s =
      let n = String.length s in
      if n >= 2 && String.sub s (n - 2) 2 = "ib" then String.sub s 0 (n - 2)
      else if s.[n - 1] = 'b' then String.sub s 0 (n - 1)
      else s
    in
    if s = "" then None
    else (
      let mult, digits =
        match s.[String.length s - 1] with
          | 'k' -> (1024, String.sub s 0 (String.length s - 1))
          | 'm' -> (1024 * 1024, String.sub s 0 (String.length s - 1))
          | 'g' -> (1024 * 1024 * 1024, String.sub s 0 (String.length s - 1))
          | _ -> (1, s)
      in
      match int_of_string_opt (String.trim digits) with
        | Some n when n > 0 -> Some (n * mult)
        | _ -> None))

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
  let backfill =
    match json |> member "backfill" with `Bool b -> b | _ -> false
  in
  let read_only =
    match json |> member "readOnly" with `Bool b -> b | _ -> false
  in
  if backfill && read_only then
    failwith
      ("backend " ^ name
     ^ ": \"backfill\" and \"readOnly\" are mutually exclusive");
  let fields =
    to_assoc json
    |> List.filter_map (fun (k, v) ->
        if
          k = "type" || k = "main" || k = "name" || k = "backfill"
          || k = "readOnly"
        then None
        else (
          match v with
            | `String s -> Some (k, s)
            | `Bool b -> Some (k, string_of_bool b)
            | `Int n -> Some (k, string_of_int n)
            (* Array fields (e.g. exec backend "command") pass through as JSON
               for the backend factory to decode. *)
            | `List _ -> Some (k, Yojson.Basic.to_string v)
            | _ -> None))
  in
  { backend_type; name; fields; main; backfill; read_only }

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
                  | `Int n -> Some (k, string_of_int n)
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

(* A size field: an integer, a size string, or absent. Kept as an option rather
   than resolved to a default here, so a caller can tell "unset" from "set to
   what the default happens to be" — [tsync print-config] shows only what the
   config actually says. *)
let parse_size_field json name =
  let open Yojson.Basic.Util in
  match json |> member name with
    | `Int n when n > 0 -> Some n
    | `String s -> (
        match parse_size s with
          | Some _ as n -> n
          | None -> failwith (Printf.sprintf "invalid %s: %s" name s))
    | `Null -> None
    | _ ->
        failwith
          (Printf.sprintf "domain %S must be a size string or integer" name)

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
    chunk_size = parse_size_field json "chunkSize";
    cache_chunk_size = parse_size_field json "cacheChunkSize";
    max_cache =
      (match json |> member "maxCache" with
        | `Int n when n > 0 -> Some n
        | `String s -> (
            match parse_size s with
              | Some n -> Some n
              | None -> failwith ("invalid maxCache: " ^ s))
        | `Null -> None
        | _ -> failwith "domain \"maxCache\" must be a size string or integer");
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

(* Shares are NOT nested per-domain: they live at a single fixed root so the share
   service's IAM/lifecycle can target one constant prefix. A share manifest is
   token-addressed and records its own chunk/dir prefixes, so its domain is
   recoverable from the body — the path needs no domain segment. *)
let shares_prefix (_ : domain) = root_prefix ^ "shares/"
