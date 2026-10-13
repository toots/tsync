open Tsync_core

exception Invalid of string

let fail path fmt =
  Printf.ksprintf
    (fun m -> raise (Invalid (if path = "" then m else path ^ ": " ^ m)))
    fmt

type value = Field_spec.value =
  | S of string
  | B of bool
  | I of int
  | F of float
  | L of string list

type backend = {
  btype : string;
  bname : string;
  role : Tsync_store.Composite.role;
  link : string option;
  fields : (string * value) list;
}

type frontend = { ftype : string; options : (string * value) list }

type domain = {
  name : Domain_name.t;
  backends : backend list;
  frontends : frontend list;
  symlinks : [ `Keep | `Follow | `Skip ] option;
  versioning : bool;
  read_only : bool;
  chunk_size : int option;
  cache_chunk_size : int option;
  max_cache : int option;
  batch_delay : float option;
  project_width : int option;
  max_entry_commands : int option;
  project_lease : float option;
  project_quarantine : float option;
  project_settle : float option;
}

let default_symlinks = `Keep

(* 05 §2.1: what the domain configures, else the application's default. *)
let tuning (d : domain) : Tuning.t =
  let v o default = Option.value ~default o in
  let t = Tuning.default in
  {
    batch_delay = v d.batch_delay t.batch_delay;
    project_width = v d.project_width t.project_width;
    max_entry_commands = v d.max_entry_commands t.max_entry_commands;
    max_entry_bytes = t.max_entry_bytes;
    project_lease = v d.project_lease t.project_lease;
    project_quarantine = v d.project_quarantine t.project_quarantine;
    project_settle = v d.project_settle t.project_settle;
  }

type link = {
  enabled : bool;
  headroom : float;
  target_delay_ms : float;
  min_rate : int;
  max_rate : int option;
}

type t = {
  client_name : string;
  tls : string option;
  max_uploads : int;
  max_chunk_buffers : int;
  max_downloads : int;
  uplink : link;
  links : (string * link) list;
  domains : domain list;
}

(* 05 §2.1: a trailing [ib] or [b] removed, an optional [k|m|g|t] in powers of
   1024, a finite positive number. *)
let parse_size s =
  let s = String.lowercase_ascii (String.trim s) in
  let s =
    if String.ends_with ~suffix:"ib" s then String.sub s 0 (String.length s - 2)
    else s
  in
  let s =
    if String.ends_with ~suffix:"b" s then String.sub s 0 (String.length s - 1)
    else s
  in
  let s = String.trim s in
  let mult, s =
    if s = "" then (1., s)
    else (
      match s.[String.length s - 1] with
        | 'k' -> (1024., String.sub s 0 (String.length s - 1))
        | 'm' -> (1048576., String.sub s 0 (String.length s - 1))
        | 'g' -> (1073741824., String.sub s 0 (String.length s - 1))
        | 't' -> (1099511627776., String.sub s 0 (String.length s - 1))
        | _ -> (1., s))
  in
  match float_of_string_opt (String.trim s) with
    | Some f when Float.is_finite f && f > 0. ->
        let v = Float.to_int (Float.round (f *. mult)) in
        if v > 0 then Some v else None
    | _ -> None

let bool_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
    | "true" | "1" | "yes" | "on" -> Some true
    | "false" | "0" | "no" | "off" -> Some false
    | _ -> None

let assoc path = function
  | `Assoc l -> l
  | `Null -> []
  | _ -> fail path "expected an object"

let check_keys path known l =
  let unknown = List.filter (fun (k, _) -> not (List.mem k known)) l in
  if unknown <> [] then
    fail path "unknown key(s) %s"
      (String.concat ", "
         (List.map (fun (k, _) -> Printf.sprintf "%S" k) unknown))

let get l k =
  match List.assoc_opt k l with Some `Null | None -> None | Some v -> Some v

let sub path k = if path = "" then k else path ^ "." ^ k

let string_field path l k =
  match get l k with
    | None -> None
    | Some (`String s) -> Some s
    | Some _ -> fail (sub path k) "expected a string"

let bool_field path l k =
  match get l k with
    | None -> None
    | Some (`Bool b) -> Some b
    | Some (`String s) -> (
        match bool_of_string_opt s with
          | Some b -> Some b
          | None -> fail (sub path k) "expected a boolean")
    | Some _ -> fail (sub path k) "expected a boolean"

let int_field path l k =
  match get l k with
    | None -> None
    | Some (`Int i) -> Some i
    | Some (`String s) -> (
        match int_of_string_opt (String.trim s) with
          | Some i -> Some i
          | None -> fail (sub path k) "expected an integer")
    | Some _ -> fail (sub path k) "expected an integer"

let float_field path l k =
  match get l k with
    | None -> None
    | Some (`Int i) -> Some (float_of_int i)
    | Some (`Float f) when Float.is_finite f -> Some f
    | Some (`String s) -> (
        match float_of_string_opt (String.trim s) with
          | Some f when Float.is_finite f -> Some f
          | _ -> fail (sub path k) "expected a number")
    | Some _ -> fail (sub path k) "expected a number"

let size_field path l k =
  match get l k with
    | None -> None
    | Some (`Int i) when i > 0 -> Some i
    | Some (`String s) -> (
        match parse_size s with
          | Some v -> Some v
          | None -> fail (sub path k) "expected a size such as 8M or 1.5 GiB")
    | Some _ -> fail (sub path k) "expected a size such as 8M or 1.5 GiB"

let required path what = function
  | Some v -> v
  | None -> fail path "required %s is missing" what

let spec_value path (fs : Field_spec.field) l =
  let p = sub path fs.name in
  match fs.kind with
    | String | Path ->
        Option.map
          (fun s -> S s)
          (match string_field path l fs.name with Some "" -> None | x -> x)
    | Bool -> Option.map (fun b -> B b) (bool_field path l fs.name)
    | Int -> Option.map (fun i -> I i) (int_field path l fs.name)
    | Float -> Option.map (fun f -> F f) (float_field path l fs.name)
    | Size -> Option.map (fun i -> I i) (size_field path l fs.name)
    | List -> (
        match get l fs.name with
          | None -> None
          | Some (`List xs) ->
              Some
                (L
                   (List.map
                      (function
                        | `String s -> s
                        | _ -> fail p "expected a list of strings")
                      xs))
          | Some _ -> fail p "expected a list of strings")

let fields_of path specs l =
  List.filter_map
    (fun (fs : Field_spec.field) ->
      match spec_value path fs l with
        | Some v ->
            (match v with
              | S text ->
                  Option.iter
                    (fun e -> fail (sub path fs.name) "%s" e)
                    (fs.check text)
              | _ -> ());
            Some (fs.name, v)
        | None ->
            if fs.required then
              fail (sub path fs.name) "required %s is missing" fs.label
            else None)
    specs

let backend_value b k = List.assoc_opt k b.fields
let str b k = match backend_value b k with Some (S s) -> Some s | _ -> None

let flag ?(default = false) fields k =
  match List.assoc_opt k fields with Some (B b) -> b | _ -> default

let num fields k =
  match List.assoc_opt k fields with Some (I i) -> Some i | _ -> None

let fstr fields k =
  match List.assoc_opt k fields with Some (S s) -> Some s | _ -> None

let ffloat fields k =
  match List.assoc_opt k fields with
    | Some (F f) -> Some f
    | Some (I i) -> Some (float_of_int i)
    | _ -> None

let parse_backend path j =
  let l = assoc path j in
  let btype =
    required (sub path "type") "string" (string_field path l "type")
  in
  let driver =
    match Tsync_store.Driver.find btype with
      | Some d -> d
      | None ->
          fail (sub path "type")
            "backend type %S is unknown or not compiled into this build \
             (built: %s)"
            btype
            (String.concat ", " (Tsync_store.Driver.names ()))
  in
  let specs = driver.fields in
  check_keys path
    (["type"; "name"; "role"; "link"]
    @ List.map (fun (f : Field_spec.field) -> f.name) specs)
    l;
  let bname =
    required (sub path "name") "string" (string_field path l "name")
  in
  if bname = "" || bname = "." || bname = ".." || String.contains bname '/' then
    fail (sub path "name") "invalid backend name %S" bname;
  let role =
    match required (sub path "role") "string" (string_field path l "role") with
      | r -> (
          match Tsync_store.Composite.role_of_string r with
            | Some r -> r
            | None ->
                fail (sub path "role")
                  "expected main, replica, backfill or readOnly")
  in
  let link = Option.map String.trim (string_field path l "link") in
  let linkless = driver.linkless in
  (match link with
    | Some _ when linkless ->
        fail path "\"link\" names a link, and a %s store has none" btype
    | Some "" -> fail (sub path "link") "a link name cannot be blank"
    | _ -> ());
  let fields = fields_of path specs l in
  let b =
    {
      btype;
      bname;
      role;
      link =
        (if linkless then None else Some (Option.value ~default:"wan" link));
      fields;
    }
  in
  b

let parse_frontend path j =
  let ftype, l =
    match j with
      | `String t -> (t, [])
      | `Assoc l ->
          (required (sub path "type") "string" (string_field path l "type"), l)
      | _ -> fail path "expected a frontend type or object"
  in
  let specs =
    match Frontend.find ftype with
      | Some f -> f.fields
      | None ->
          fail path
            "frontend type %S is unknown or not compiled into this build \
             (built: %s)"
            ftype
            (String.concat ", " (Frontend.names ()))
  in
  check_keys path
    ("type" :: List.map (fun (f : Field_spec.field) -> f.name) specs)
    l;
  let options = fields_of path specs l in
  { ftype; options }

let parse_link path j =
  let l = assoc path j in
  check_keys path
    ["enabled"; "headroom"; "targetDelayMs"; "minRate"; "maxRate"]
    l;
  (l, path)

let link_of
    ?(base =
      {
        enabled = true;
        headroom = 0.8;
        target_delay_ms = 50.;
        min_rate = 65536;
        max_rate = None;
      }) (l, path) =
  let v =
    {
      enabled = Option.value ~default:base.enabled (bool_field path l "enabled");
      headroom =
        Option.value ~default:base.headroom (float_field path l "headroom");
      target_delay_ms =
        Option.value ~default:base.target_delay_ms
          (float_field path l "targetDelayMs");
      min_rate =
        Option.value ~default:base.min_rate (size_field path l "minRate");
      max_rate =
        (match size_field path l "maxRate" with
          | Some r -> Some r
          | None -> base.max_rate);
    }
  in
  if v.headroom <= 0. || v.headroom > 1. then
    fail (sub path "headroom") "must lie in (0, 1]";
  if v.target_delay_ms < 5. then
    fail (sub path "targetDelayMs") "must be at least 5";
  (match v.max_rate with
    | Some m when m < v.min_rate -> fail (sub path "maxRate") "is below minRate"
    | _ -> ());
  v

let parse_domain path j =
  let l = assoc path j in
  check_keys path
    [
      "name";
      "backends";
      "frontends";
      "symlinks";
      "versioning";
      "readOnly";
      "chunkSize";
      "cacheChunkSize";
      "maxCache";
      "batchDelay";
      "projectWidth";
      "maxEntryCommands";
      "projectLease";
      "projectQuarantine";
      "projectSettle";
    ]
    l;
  let raw_name =
    required (sub path "name") "string" (string_field path l "name")
  in
  let backends =
    match get l "backends" with
      | Some (`List bs) ->
          List.mapi
            (fun i b ->
              parse_backend (Printf.sprintf "%s.backends[%d]" path i) b)
            bs
      | Some _ -> fail (sub path "backends") "expected an array"
      | None -> fail (sub path "backends") "required array is missing"
  in
  let local_store = List.exists (fun b -> b.btype = "local") backends in
  let name =
    match Domain_name.of_string ~local_store raw_name with
      | Ok n -> n
      | Error e -> fail (sub path "name") "%s" e
  in
  let frontends =
    match get l "frontends" with
      | Some (`List (_ :: _ as fs)) ->
          List.mapi
            (fun i f ->
              parse_frontend (Printf.sprintf "%s.frontends[%d]" path i) f)
            fs
      | Some _ -> fail (sub path "frontends") "expected a non-empty array"
      | None -> fail (sub path "frontends") "required array is missing"
  in
  let types = List.map (fun f -> f.ftype) frontends in
  List.iter
    (fun t ->
      if List.length (List.filter (( = ) t) types) > 1 then
        fail (sub path "frontends") "%s is listed twice" t)
    types;
  if
    List.length
      (List.filter
         (fun t ->
           match Frontend.find t with
             | Some f -> f.presenting <> None
             | None -> false)
         types)
    > 1
  then
    fail (sub path "frontends")
      "at most one presenting frontend (fuse, file_provider, android) per \
       domain";
  let names = List.map (fun b -> String.lowercase_ascii b.bname) backends in
  List.iter
    (fun n ->
      if List.length (List.filter (( = ) n) names) > 1 then
        fail (sub path "backends")
          "backend name %S is used twice (ignoring case)" n)
    names;
  let roles = List.map (fun b -> b.role) backends in
  let has r = List.mem r roles in
  if not (has Main) then (
    if has Replica then
      fail (sub path "backends")
        "a replica is a copy of a source of truth: this domain has no main";
    if has Backfill then
      fail (sub path "backends")
        "a backfill has nothing to fill it from: this domain has no main";
    if not (has Read_only) then
      fail (sub path "backends")
        "nothing here can answer a read: add a main or a readOnly store");
  let symlinks =
    Option.map
      (function
        | "keep" -> `Keep
        | "follow" -> `Follow
        | "skip" -> `Skip
        | _ -> fail (sub path "symlinks") "expected keep, follow or skip")
      (string_field path l "symlinks")
  in
  let at_least k least what v =
    Option.iter (fun v -> if v < least then fail (sub path k) what) v;
    v
  in
  let seconds k =
    match float_field path l k with
      | Some v when v <= 0. -> fail (sub path k) "expected seconds above 0"
      | v -> v
  in
  let batch_delay =
    at_least "batchDelay" 0. "expected seconds, 0 or more"
      (float_field path l "batchDelay")
  in
  let project_width =
    at_least "projectWidth" 1 "expected an integer of 1 or more"
      (int_field path l "projectWidth")
  in
  let max_entry_commands =
    at_least "maxEntryCommands" 1 "expected an integer of 1 or more"
      (int_field path l "maxEntryCommands")
  in
  let project_lease = seconds "projectLease" in
  let project_quarantine = seconds "projectQuarantine" in
  let project_settle = seconds "projectSettle" in
  let versioning =
    required (sub path "versioning") "boolean" (bool_field path l "versioning")
  in
  let chunk_size = size_field path l "chunkSize" in
  (match chunk_size with
    | Some cs when cs < Chunking.chunk_size_min || cs > Chunking.chunk_size_max
      ->
        fail (sub path "chunkSize") "must lie between 256 KiB and 256 MiB"
    | _ -> ());
  let d =
    {
      name;
      backends =
        List.stable_sort
          (fun a b ->
            compare
              (Tsync_store.Composite.read_rank a.role)
              (Tsync_store.Composite.read_rank b.role))
          backends;
      frontends;
      symlinks;
      versioning;
      read_only =
        Option.value ~default:false (bool_field path l "readOnly")
        || not (has Main);
      chunk_size;
      cache_chunk_size = size_field path l "cacheChunkSize";
      max_cache = size_field path l "maxCache";
      batch_delay;
      project_width;
      max_entry_commands;
      project_lease;
      project_quarantine;
      project_settle;
    }
  in
  (* 05 §2.1: behind a main that states its settings a timing left out is the
     main's, so only those configured are compared here, and {!in_force}
     refuses one that differs from the main's. *)
  let stated_by_main =
    List.exists
      (fun b -> b.role = Tsync_store.Composite.Main && b.btype = "http-proxy")
      d.backends
  in
  let t = tuning d in
  let lease, quarantine, settle =
    if stated_by_main then
      (d.project_lease, d.project_quarantine, d.project_settle)
    else (Some t.project_lease, Some t.project_quarantine, Some t.project_settle)
  in
  let below a b = match (a, b) with Some a, Some b -> a < b | _ -> true in
  if
    not (below lease quarantine && below quarantine settle && below lease settle)
  then
    fail path
      "the projection timings in force must satisfy projectLease < \
       projectQuarantine < projectSettle, and are %g, %g and %g"
      t.project_lease t.project_quarantine t.project_settle;
  d

(* 05 §2.1, domain-wide settings: what a main serving this domain states. *)
let stated (d : domain) : Tsync_store.Store.domain_settings =
  let t = tuning d in
  {
    chunk = Option.value ~default:Chunking.default_chunk_size d.chunk_size;
    symlinks = Option.value ~default:default_symlinks d.symlinks;
    lease = t.project_lease;
    quarantine = t.project_quarantine;
    settle = t.project_settle;
    entry_commands = t.max_entry_commands;
    projector = None;
  }

(* 05 §2.1, domain-wide settings: the main's where it states them, and a
   configured value that differs from the main's refused. The chunk size is
   the remote layer's (01 §3.5). *)
let in_force (d : domain) (main : Tsync_store.Store.domain_settings option) =
  let own = tuning d in
  match main with
    | None -> (own, Option.value ~default:default_symlinks d.symlinks)
    | Some m ->
        let differs what configured stated show =
          match configured with
            | Some c when c <> stated ->
                Fail.invalid
                  "%s is configured with %s %s and its main states %s"
                  (Domain_name.to_string d.name)
                  what (show c) (show stated)
            | _ -> ()
        in
        let seconds = Printf.sprintf "%g s" in
        differs "symlinks" d.symlinks m.symlinks (fun p ->
            fst (List.find (fun (_, q) -> q = p) Tsync_store.Store.policies));
        differs "projectLease" d.project_lease m.lease seconds;
        differs "projectQuarantine" d.project_quarantine m.quarantine seconds;
        differs "projectSettle" d.project_settle m.settle seconds;
        let max_entry_commands =
          match d.max_entry_commands with
            | Some c when c > m.entry_commands ->
                Fail.invalid
                  "%s is configured with maxEntryCommands %d, above the %d its \
                   main states"
                  (Domain_name.to_string d.name)
                  c m.entry_commands
            | Some c -> c
            | None -> m.entry_commands
        in
        ( {
            own with
            max_entry_commands;
            project_lease = m.lease;
            project_quarantine = m.quarantine;
            project_settle = m.settle;
          },
          m.symlinks )

(* 05 §2.1: where each domain-wide setting in force comes from. *)
let sources (d : domain) (main : Tsync_store.Store.domain_settings option) =
  let from configured =
    if configured then "config" else if main <> None then "main" else "default"
  in
  [
    ("chunkSize", from (d.chunk_size <> None));
    ("symlinks", from (d.symlinks <> None));
    ("projectLease", from (d.project_lease <> None));
    ("projectQuarantine", from (d.project_quarantine <> None));
    ("projectSettle", from (d.project_settle <> None));
    ("maxEntryCommands", from (d.max_entry_commands <> None));
  ]

let hostname () = try Unix.gethostname () with _ -> "tsync"

let of_json j =
  let l = assoc "" j in
  check_keys ""
    [
      "name";
      "tls";
      "maxUploads";
      "maxChunkBuffers";
      "maxDownloads";
      "uplink";
      "links";
      "domains";
    ]
    l;
  let nonneg k d =
    match int_field "" l k with
      | Some i when i < 0 -> fail k "must not be negative"
      | Some 0 | None -> d
      | Some i -> i
  in
  let max_uploads = nonneg "maxUploads" 4 in
  let domains =
    match get l "domains" with
      | Some (`List ds) ->
          List.mapi
            (fun i d -> parse_domain (Printf.sprintf "domains[%d]" i) d)
            ds
      | Some _ -> fail "domains" "expected an array"
      | None -> fail "domains" "required array is missing"
  in
  let dnames =
    List.map
      (fun d -> String.lowercase_ascii (Domain_name.to_string d.name))
      domains
  in
  List.iter
    (fun n ->
      if List.length (List.filter (( = ) n) dnames) > 1 then
        fail "domains" "domain name %S is used twice (ignoring case)" n)
    dnames;
  let uplink =
    link_of (parse_link "uplink" (Option.value ~default:`Null (get l "uplink")))
  in
  let used =
    List.sort_uniq compare
      (List.concat_map
         (fun d -> List.filter_map (fun b -> b.link) d.backends)
         domains)
  in
  let links =
    List.map
      (fun (name, j) ->
        if not (List.mem name used) then
          fail ("links." ^ name) "no backend uses this link";
        (name, link_of ~base:uplink (parse_link ("links." ^ name) j)))
      (assoc "links" (Option.value ~default:`Null (get l "links")))
  in
  let name =
    match string_field "" l "name" with
      | Some "" -> fail "name" "must not be empty"
      | Some n -> n
      | None -> hostname ()
  in
  let tls =
    match string_field "" l "tls" with
      | Some ("native" | "openssl") as t -> t
      | None -> None
      | Some _ -> fail "tls" "expected native or openssl"
  in
  {
    client_name = name;
    tls;
    max_uploads;
    max_chunk_buffers = nonneg "maxChunkBuffers" max_uploads;
    max_downloads = nonneg "maxDownloads" 8;
    uplink;
    links;
    domains;
  }

let of_string s =
  match Yojson.Safe.from_string s with
    | j -> of_json j
    | exception Yojson.Json_error e -> raise (Invalid ("not valid JSON: " ^ e))

let link_settings t name =
  match List.assoc_opt name t.links with Some l -> l | None -> t.uplink

let frontend d ftype = List.find_opt (fun f -> f.ftype = ftype) d.frontends

let find_domain t name =
  List.find_opt (fun d -> Domain_name.to_string d.name = name) t.domains

(* 05 §2.2 and 07 §5.1: an explicit name, the default domain if configured,
   else the only domain. *)
let resolve ?name ?default t =
  match name with
    | Some n -> (
        match find_domain t n with
          | Some d -> d
          | None -> Fail.raise_ Fail.Invalid "domain not found: %s" n)
    | None -> (
        match Option.bind default (find_domain t) with
          | Some d -> d
          | None -> (
              match t.domains with
                | [] -> Fail.raise_ Fail.Invalid "no domains configured"
                | [d] -> d
                | _ ->
                    Fail.raise_ Fail.Invalid
                      "multiple domains configured \xe2\x80\x94 use --domain \
                       to select"))

let is_secret ~specs name =
  match List.find_opt (fun (f : Field_spec.field) -> f.name = name) specs with
    | Some f -> f.secret
    | None -> true

(* security §10.3: masking fails closed, a field without a spec is masked. *)
type shown = Secret | Shown of value

let masked_fields ~specs fields =
  List.map
    (fun (k, v) -> (k, if is_secret ~specs k then Secret else Shown v))
    fields

let value_to_string = function
  | S s -> s
  | B b -> string_of_bool b
  | I i -> string_of_int i
  | F f -> Printf.sprintf "%g" f
  | L l -> String.concat ", " l

let uplink_settings (l : link) =
  {
    Tsync_store.Uplink.enabled = l.enabled;
    law =
      {
        headroom = l.headroom;
        target_delay = l.target_delay_ms /. 1000.;
        min_rate = float_of_int l.min_rate;
        max_rate = Option.map float_of_int l.max_rate;
      };
  }
