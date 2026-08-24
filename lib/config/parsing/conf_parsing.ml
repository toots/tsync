type role = [ `Main | `Replica | `Backfill | `ReadOnly ]

type backend_config = {
  backend_type : string;
  name : string;
  fields : (string * string) list;
  role : role;
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
  max_chunk_buffers : int;
  max_downloads : int;
  domains : domain list;
}

let roles : role list = [`Main; `Replica; `Backfill; `ReadOnly]

let role_name : role -> string = function
  | `Main -> "main"
  | `Replica -> "replica"
  | `Backfill -> "backfill"
  | `ReadOnly -> "readOnly"

let role_of_string s = List.find_opt (fun r -> role_name r = s) roles
let default_max_uploads = 4
let default_max_downloads = 8

(* A decimal mantissa is accepted so that what {!Metrics.human_bytes} prints —
   the one spelling shown to a person — can be typed straight back in. *)
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
    let s = String.trim s in
    if s = "" then None
    else (
      let mult, digits =
        let chop m = (m, String.sub s 0 (String.length s - 1)) in
        match s.[String.length s - 1] with
          | 'k' -> chop 1024
          | 'm' -> chop (1024 * 1024)
          | 'g' -> chop (1024 * 1024 * 1024)
          | 't' -> chop (1024 * 1024 * 1024 * 1024)
          | _ -> (1, s)
      in
      match float_of_string_opt (String.trim digits) with
        | Some f when f > 0. && Float.is_finite f ->
            let n = int_of_float (Float.round (f *. float_of_int mult)) in
            if n > 0 then Some n else None
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
  let expected =
    String.concat ", "
      (List.map (fun r -> Printf.sprintf "%S" (role_name r)) roles)
  in
  let role =
    match json |> member "role" with
      | `String s -> (
          match role_of_string s with
            | Some r -> r
            | None ->
                failwith
                  (Printf.sprintf
                     "backend %s: unknown role %S (expected one of %s)" name s
                     expected))
      | _ ->
          failwith
            (Printf.sprintf
               "backend %s: missing required \"role\" field (one of %s)" name
               expected)
  in
  let fields =
    to_assoc json
    |> List.filter_map (fun (k, v) ->
        if k = "type" || k = "name" || k = "role" then None
        else (
          match v with
            | `String s -> Some (k, s)
            | `Bool b -> Some (k, string_of_bool b)
            | `Int n -> Some (k, string_of_int n)
            (* Array fields (the exec backend's "command") pass through as JSON
               for the backend factory to decode. *)
            | `List _ -> Some (k, Yojson.Basic.to_string v)
            | _ -> None))
  in
  { backend_type; name; fields; role }

(* Reads use the head, so config order picks the read primary. *)
let order_backends backends =
  let rank b =
    match b.role with
      | `Main -> 0
      | `Replica -> 1
      | `ReadOnly -> 2
      | `Backfill -> 3
  in
  List.stable_sort (fun a b -> compare (rank a) (rank b)) backends

(* A bare type name ["fuse"] is shorthand for [{"type": "fuse"}]. Extra keys are
   kept as string fields. *)
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

(* An integer, a size string, or absent. Kept optional rather than defaulted here
   so a caller can tell "unset" from "set to the default value". *)
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

(* A domain is either writable (at least one [main], which every replica and
   backfill target copies) or purely read-only. A replica or backfill target with
   no main is a copy of nothing. *)
let validate_roles name backends =
  let count r = List.length (List.filter (fun b -> b.role = r) backends) in
  let fail fmt = failwith (Printf.sprintf ("domain %s: " ^^ fmt) name) in
  if count `Main = 0 then begin
    if count `Replica > 0 then
      fail
        "a backend has \"role\": \"replica\" but none has \"main\" — a replica \
         is a copy of a source of truth, so there has to be one";
    if count `Backfill > 0 then
      fail
        "a backend has \"role\": \"backfill\" but none has \"main\" — there is \
         nothing to fill it from";
    if count `ReadOnly = 0 then
      fail
        "needs at least one backend with \"role\": \"main\" (writable) or \
         \"readOnly\" (a read-only domain); nothing here can answer a read"
  end

let parse_domain json =
  let open Yojson.Basic.Util in
  let name = json |> member "name" |> to_string in
  let backends =
    json |> member "backends" |> to_list |> List.map parse_backend
  in
  validate_roles name backends;
  {
    name;
    backends;
    frontends =
      (match json |> member "frontends" with
        | `List (_ :: _ as l) -> List.map parse_frontend l
        | _ ->
            failwith
              "domain config missing required non-empty \"frontends\" array");
    symlink_policy = parse_symlink_policy json;
    versioning = json |> member "versioning" |> to_bool;
    (* With nothing writable a write cannot land, so the domain is read-only
       whether it says so or not: EROFS at the mount beats a backend error per
       attempt. *)
    read_only =
      (match json |> member "readOnly" with `Bool b -> b | _ -> false)
      || not (List.exists (fun b -> b.role <> `ReadOnly) backends);
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

let of_json json =
  let open Yojson.Basic.Util in
  let max_uploads =
    match json |> member "maxUploads" with
      | `Int n when n > 0 -> n
      | _ -> default_max_uploads
  in
  {
    name =
      (match json |> member "name" with
        | `String s -> s
        | _ -> Unix.gethostname ());
    tls = (match json |> member "tls" with `String s -> Some s | _ -> None);
    max_uploads;
    (* Defaults to [max_uploads]: only a host short on memory relative to its
       chunk size needs to set it. *)
    max_chunk_buffers =
      (match json |> member "maxChunkBuffers" with
        | `Int n when n > 0 -> n
        | _ -> max_uploads);
    max_downloads =
      (match json |> member "maxDownloads" with
        | `Int n when n > 0 -> n
        | _ -> default_max_downloads);
    domains = json |> member "domains" |> to_list |> List.map parse_domain;
  }

let load path =
  of_json
    (match Sys.getenv_opt "TSYNC_CONFIG_JSON" with
      | Some s -> Yojson.Basic.from_string s
      | None -> Yojson.Basic.from_file path)

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

(* One folder per domain, so a domain is dropped with a single prefix delete.
   Chunks are per-domain: no cross-domain dedup. *)
let domain_root (d : domain) = root_prefix ^ d.name ^ "/"
let domain_prefix d = domain_root d ^ "manifests/"
let chunk_prefix d = domain_root d ^ "chunks/"
let versions_prefix d = domain_root d ^ "versions/"
let journal_prefix d = domain_root d ^ "journal/"
let cursor_key d = Stored_key.in_space ~prefix:(domain_root d) "cursor"

(* Shares sit at one fixed root rather than per domain, so the share service's
   IAM and lifecycle target a constant prefix. A share manifest is token-addressed
   and records its own chunk/dir prefixes, so its domain is recoverable from the
   body. *)
let shares_prefix (_ : domain) = root_prefix ^ "shares/"

(* Where fuse mounts a domain: its [mountPoint] option, else ~/tsync/<domain>.
   Here rather than in the CLI because it is derived entirely from the config,
   and both the CLI and the tray have to agree on the answer. *)
let mount_point_of (d : domain) =
  let opt =
    List.find_map
      (fun (f : frontend_config) ->
        if f.frontend_type = "fuse" then List.assoc_opt "mountPoint" f.options
        else None)
      d.frontends
  in
  match opt with
    | Some p when p <> "" -> p
    | _ -> Filename.concat (Sys.getenv "HOME") ("tsync/" ^ d.name)

(* fileproviderd names the domain's folder "<app name>-<domain displayName>"
   after dropping characters it will not put in a path ("Jellyfin Media" becomes
   "TsyncApp-JellyfinMedia"). The rule is undocumented, so it is found by
   looking, comparing on letters and digits alone. *)
let alnum s =
  String.to_seq (String.lowercase_ascii s)
  |> Seq.filter (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
  |> String.of_seq

let cloud_storage_root () =
  Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"

let is_domain_dir ~domain_name dir = alnum dir = alnum ("TsyncApp" ^ domain_name)

let cloud_storage_dir ~domain_name =
  let root = cloud_storage_root () in
  match Sys.readdir root with
    | exception _ -> None
    | dirs ->
        Array.find_opt (is_domain_dir ~domain_name) dirs
        |> Option.map (Filename.concat root)

(* Every root a caller may name a file of this domain under, in the order they
   are tried. The data dir is last and is not per domain, so a path under it
   answers to the first domain configured — where the two before it name one. *)
let roots_of ~data_dir (d : domain) =
  List.filter_map Fun.id
    [
      Some (mount_point_of d);
      cloud_storage_dir ~domain_name:d.name;
      Some data_dir;
    ]
