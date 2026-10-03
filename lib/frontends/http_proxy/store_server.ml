open Tsync_core
open Tsync_store
open Tsync_http
module W = Tsync_http_proxy_client.Proxy_wire

type route = {
  name : string;
  domain : Domain_name.t;
  secret : string;
  read_only : bool;
  chunk_size : int option;
  store : Store.t;
  share : Share_server.t option;  (** [Some] when the route serves share links *)
}

let default_max_concurrent = 16
let queue_per_slot = 4

type t = {
  routes : route list;
  listener : Proxy_options.listener option;
  bound : int;
  slots : Rt.Semaphore.t;
  pending : int Atomic.t;
  body_memory : int Atomic.t;
  gates : Watch_gates.t;
  share_slots : Rt.Semaphore.t;
  tallies : (string, int Atomic.t) Hashtbl.t;
  traffic : (string, traffic) Hashtbl.t;  (** per route name *)
  total : traffic;  (** every answer, shares included *)
  in_flight : int Atomic.t;
}

and traffic = { read : int Atomic.t; written : int Atomic.t }

let tally_names =
  [
    "get";
    "getRange";
    "watch";
    "head";
    "put";
    "putIfAbsent";
    "putIfUnchanged";
    "checksum";
    "delete";
    "getMulti";
    "childrenMulti";
    "deleteMulti";
    "copy";
    "list";
    "shareUrl";
    "chunkSize";
    "maxConcurrency";
    "verified";
    "share";
    "page";
    "stats";
    "domains";
    "unauthorized";
    "notFound";
    "badRequest";
    "tooLarge";
    "busy";
    "error";
  ]

(* §A5: the configured bound, else the tightest store opinion, else the
   default. *)
let derive_bound ?max_concurrent routes =
  match max_concurrent with
    | Some n -> (n, "max_concurrent")
    | None -> (
        match
          List.filter_map
            (fun r ->
              try
                (r.store.capabilities (Key.domain_prefix r.domain))
                  .max_concurrency
              with _ -> None)
            routes
        with
          | [] -> (default_max_concurrent, "default")
          | l -> (List.fold_left min max_int l, "the stores' opinion"))

let create ?max_concurrent ?listener routes =
  let bound, origin = derive_bound ?max_concurrent routes in
  Log.info "http-proxy: at most %d data operations at once (%s)" bound origin;
  {
    routes;
    listener;
    bound;
    slots = Rt.Semaphore.create ~name:"http-proxy data" bound;
    pending = Atomic.make 0;
    body_memory = Atomic.make 0;
    gates = Watch_gates.create ();
    share_slots =
      Rt.Semaphore.create ~name:"share responses"
        (match listener with Some l -> l.max_share_responses | None -> 64);
    tallies =
      (let h = Hashtbl.create 32 in
       List.iter (fun n -> Hashtbl.replace h n (Atomic.make 0)) tally_names;
       h);
    total = { read = Atomic.make 0; written = Atomic.make 0 };
    in_flight = Atomic.make 0;
    traffic =
      (let h = Hashtbl.create 4 in
       List.iter
         (fun route ->
           Hashtbl.replace h route.name
             { read = Atomic.make 0; written = Atomic.make 0 })
         routes;
       h);
  }

let count t name = Option.iter Atomic.incr (Hashtbl.find_opt t.tallies name)
let text = Server.text
let empty status = { Server.status; headers = []; body = Empty }

let json ?(status = 200) j =
  {
    Server.status;
    headers = [("content-type", "application/json")];
    body = String (Yojson.Safe.to_string j);
  }

exception Answer of Server.response

let answer r = raise (Answer r)

let bad_request t =
  count t "badRequest";
  answer (text 400 "bad request")

let unauthorized t =
  count t "unauthorized";
  answer (text 401 "unauthorized")

type op =
  | Get of Key.t
  | Range of Key.t * int * int
  | Watch of Key.t * string option * float
  | Head of Key.t
  | Put of Key.t
  | Claim of Key.t
  | Put_if_unchanged of Key.t * string option
      (** the etag the client read, or [None] for no object *)
  | Checksum of Key.t * string
  | Delete of Key.t
  | Get_multi
  | Children_multi
  | Delete_multi
  | Copy of Key.t * Key.t
  | List of Key.prefix * int option
  | List_key of Key.t
  | Share_url of Key.prefix
  | Chunk_size of Key.prefix
  | Max_concurrency of Key.prefix
  | Verified of Key.prefix

let tally = function
  | Get _ -> "get"
  | Range _ -> "getRange"
  | Watch _ -> "watch"
  | Head _ -> "head"
  | Put _ -> "put"
  | Claim _ -> "putIfAbsent"
  | Put_if_unchanged _ -> "putIfUnchanged"
  | Checksum _ -> "checksum"
  | Delete _ -> "delete"
  | Get_multi -> "getMulti"
  | Children_multi -> "childrenMulti"
  | Delete_multi -> "deleteMulti"
  | Copy _ -> "copy"
  | List _ | List_key _ -> "list"
  | Share_url _ -> "shareUrl"
  | Chunk_size _ -> "chunkSize"
  | Max_concurrency _ -> "maxConcurrency"
  | Verified _ -> "verified"

(* §A5: data operations are gated, metadata never waits behind transfers. *)
let is_data = function
  | Get _ | Range _ | Get_multi | Children_multi | Put _ | Put_if_unchanged _
  | Checksum _ ->
      true
  | _ -> false

(* §5: decimal digits only, at most 15. *)
let number s =
  if
    s <> ""
    && String.length s <= 15
    && String.for_all (fun c -> c >= '0' && c <= '9') s
  then int_of_string_opt s
  else None

let wait_seconds s =
  let ok =
    s <> ""
    && String.for_all (fun c -> (c >= '0' && c <= '9') || c = '.') s
    && List.length (String.split_on_char '.' s) <= 2
    && s.[0] <> '.'
  in
  if not ok then None
  else Option.map (fun f -> Float.min f W.watch_max) (float_of_string_opt s)

let if_absent = function
  | "1" -> Some true
  | v -> (
      match String.lowercase_ascii v with
        | "true" | "yes" | "on" -> Some true
        | "0" | "false" | "no" | "off" -> Some false
        | _ -> None)

let parse_op t (r : Server.request) params =
  let param k = List.assoc_opt k params in
  let key s =
    match Key.of_string s with Some k -> k | None -> bad_request t
  in
  let prefix s =
    match Key.prefix_of_string s with Some p -> p | None -> bad_request t
  in
  let only allowed =
    if List.exists (fun (k, _) -> not (List.mem k allowed)) params then
      bad_request t
  in
  let needs_prefix () =
    only ["prefix"];
    prefix (Option.value ~default:"" (param "prefix"))
  in
  match (r.meth, String.split_on_char '/' r.path) with
    | meth, [""; "o"; enc] -> (
        let k =
          match W.decode_key enc with Some k -> k | None -> bad_request t
        in
        match meth with
          | "GET" -> (
              match (param "wait", param "offset", param "length") with
                | Some w, None, None ->
                    only ["wait"; "last_seen"];
                    let w =
                      match wait_seconds w with
                        | Some w -> w
                        | None -> bad_request t
                    in
                    Watch (k, param "last_seen", w)
                | None, Some o, Some l -> (
                    only ["offset"; "length"];
                    match (number o, number l) with
                      | Some o, Some l when l >= 1 -> Range (k, o, l)
                      | _ -> bad_request t)
                | None, None, None ->
                    only [];
                    Get k
                | _ -> bad_request t)
          | "HEAD" ->
              only [];
              Head k
          | "PUT" -> (
              only ["if_absent"; "if_match"; "if_none_match"];
              match
                (param "if_absent", param "if_match", param "if_none_match")
              with
                | None, None, None -> Put k
                | Some v, None, None -> (
                    match if_absent v with
                      | Some true -> Claim k
                      | Some false -> Put k
                      | None -> bad_request t)
                | None, Some etag, None when etag <> "" ->
                    Put_if_unchanged (k, Some etag)
                | None, None, Some "1" -> Put_if_unchanged (k, None)
                | _ -> bad_request t)
          | "DELETE" ->
              only [];
              Delete k
          | _ -> answer (text 405 "method not allowed"))
    | "GET", [""; "checksum"; enc] -> (
        only ["algo"];
        let k =
          match W.decode_key enc with Some k -> k | None -> bad_request t
        in
        match param "algo" with
          | Some algo when Checksum.known algo -> Checksum (k, algo)
          | _ -> bad_request t)
    | "POST", [""; "get-multi"] ->
        only [];
        Get_multi
    | "POST", [""; "children-multi"] ->
        only [];
        Children_multi
    | "POST", [""; "delete-multi"] ->
        only [];
        Delete_multi
    | "POST", [""; "copy"] -> (
        only ["src"; "dst"];
        match (param "src", param "dst") with
          | Some s, Some d -> Copy (key s, key d)
          | _ -> bad_request t)
    | "GET", [""; "list"] -> (
        only ["mode"; "prefix"; "max_keys"];
        if param "mode" <> Some "all" then bad_request t;
        let raw = Option.value ~default:"" (param "prefix") in
        let max_keys =
          Option.map
            (fun n -> match number n with Some n -> n | None -> bad_request t)
            (param "max_keys")
        in
        match (Key.prefix_of_string raw, Key.of_string raw) with
          | Some p, _ -> List (p, max_keys)
          | None, Some k -> List_key k
          | None, None -> bad_request t)
    | "GET", [""; "share-url"] -> Share_url (needs_prefix ())
    | "GET", [""; "chunk-size"] -> Chunk_size (needs_prefix ())
    | "GET", [""; "max-concurrency"] -> Max_concurrency (needs_prefix ())
    | "GET", [""; "verified"] -> Verified (needs_prefix ())
    | _ ->
        count t "notFound";
        answer (text 404 "not found")

let key_names = function
  | Get k
  | Range (k, _, _)
  | Watch (k, _, _)
  | Head k
  | Put k
  | Claim k
  | Put_if_unchanged (k, _)
  | Checksum (k, _)
  | Delete k ->
      [Key.to_string k]
  | Copy (s, d) -> [Key.to_string s; Key.to_string d]
  | List_key k -> [Key.to_string k]
  | List (p, _) | Share_url p | Chunk_size p | Max_concurrency p | Verified p ->
      [Key.prefix_to_string p]
  | Get_multi | Children_multi | Delete_multi -> []

(* §A4.3, security §5.2: the first name picks the route, every name must lie
   in it; nothing is narrowed. *)
let within r name =
  List.exists
    (fun root -> String.starts_with ~prefix:(Key.prefix_to_string root) name)
    (Key.roots r.domain)

let route_for t names =
  match names with
    | [] -> None
    | first :: _ -> (
        match List.find_opt (fun r -> within r first) t.routes with
          | Some r when List.for_all (within r) names -> Some r
          | _ -> None)

let share_space = Key.prefix_to_string Key.shares
let in_share_space name = String.starts_with ~prefix:share_space name

(* security §6.4: [tsync/shares/<token>] is a manifest, anything deeper a cache
   artifact. *)
let is_manifest_name name =
  in_share_space name
  && not
       (String.contains
          (String.sub name
             (String.length share_space)
             (String.length name - String.length share_space))
          '/')

let stored_domain route name =
  match Option.bind (Key.of_string name) route.store.get_opt with
    | Some b -> Share_server.manifest_domain (Bigstring.to_string b)
    | None -> None

(* The routes that may serve a share-space operation, before any signature. *)
let share_candidates t op body names =
  if not (List.for_all in_share_space names) then []
  else (
    match (op, names) with
      | (Get_multi | Children_multi | Delete_multi | Copy _), _
        when List.exists is_manifest_name names ->
          []
      | (Put _ | Claim _ | Put_if_unchanged _), [name]
        when is_manifest_name name -> (
          match Share_server.manifest_domain (Bigstring.to_string body) with
            | None -> []
            | Some d ->
                List.filter
                  (fun r ->
                    Domain_name.equal r.domain d
                    &&
                      match stored_domain r name with
                      | None -> true
                      | Some held -> Domain_name.equal held d)
                  t.routes)
      | _, [name] when is_manifest_name name ->
          let owning =
            List.filter (fun r -> stored_domain r name = Some r.domain) t.routes
          in
          let held_anywhere =
            List.exists
              (fun r ->
                match Key.of_string name with
                  | Some k -> r.store.head_opt k <> None
                  | None -> false)
              t.routes
          in
          if owning <> [] then owning
          else if held_anywhere then []
          else t.routes
      | _ -> t.routes)

let bulk_names t body =
  match Yojson.Safe.from_string (Bigstring.to_string body) with
    | `List (_ :: _ as l) when List.length l <= W.bulk_keys_max ->
        List.map (function `String s -> s | _ -> bad_request t) l
    | _ -> bad_request t
    | exception Yojson.Json_error _ -> bad_request t

let header (r : Server.request) k = Codec.header r.headers k

let signed_target (r : Server.request) params =
  if params = [] then r.path else r.path ^ "?" ^ W.canonical_query params

let verifies (r : Server.request) params body secret =
  match (header r "x-tsync-timestamp", header r "x-tsync-signature") with
    | Some timestamp, Some signature ->
        W.verify ~secret ~meth:r.meth ~target:(signed_target r params)
          ~timestamp ~signature body
        || W.verify ~secret ~meth:r.meth ~target:r.target ~timestamp ~signature
             body
    | _ -> false

let fresh (r : Server.request) =
  match header r "x-tsync-timestamp" with
    | Some ts -> W.fresh ~now:(Unix.gettimeofday ()) ts
    | None -> false

let body_limit t op =
  let l = t.listener in
  match op with
    | Put _ | Claim _ | Put_if_unchanged _ ->
        Option.fold
          ~none:(256 * 1024 * 1024)
          ~some:(fun (l : Proxy_options.listener) -> l.max_put_body)
          l
    | Get_multi | Children_multi | Delete_multi ->
        Option.fold ~none:(1024 * 1024)
          ~some:(fun (l : Proxy_options.listener) -> l.max_bulk_body)
          l
    | _ -> 0

let max_body_memory t =
  Option.fold
    ~none:(1024 * 1024 * 1024)
    ~some:(fun (l : Proxy_options.listener) -> l.max_body_memory)
    t.listener

(* §A5: past the bound, a bounded queue; past the queue, 503 at once. *)
let admitted t f =
  if Atomic.fetch_and_add t.pending 1 >= t.bound * (1 + queue_per_slot) then (
    Atomic.decr t.pending;
    count t "busy";
    answer (text 503 "busy"))
  else
    Fun.protect
      ~finally:(fun () -> Atomic.decr t.pending)
      (fun () -> Rt.Semaphore.with_slot t.slots f)

(* A body arrives within a minute plus a second per 16 KiB: a slow uplink fits,
   a drip holding reserved memory does not. *)
let body_deadline n = 60. +. (float_of_int n /. 16384.)

(* security §11: bodies are reserved from their declared length before a byte
   is read. *)
let read_within t (r : Server.request) read_body limit =
  match r.body_length with
    | `Length 0 -> Bigstring.empty
    | `Length n when n > limit ->
        count t "tooLarge";
        answer (text 413 "too large")
    | _ when limit = 0 -> bad_request t
    | length ->
        let reserve = match length with `Length n -> n | _ -> limit in
        if
          Atomic.fetch_and_add t.body_memory reserve + reserve
          > max_body_memory t
        then (
          ignore (Atomic.fetch_and_add t.body_memory (-reserve));
          count t "busy";
          answer (text 503 "busy"));
        Fun.protect
          ~finally:(fun () ->
            ignore (Atomic.fetch_and_add t.body_memory (-reserve)))
          (fun () ->
            try
              Rt.with_timeout (body_deadline reserve) (fun () ->
                  read_body ~limit)
            with
              | Server.Body_too_large ->
                  count t "tooLarge";
                  answer (text 413 "too large")
              | Rt.Timeout -> answer (text 408 "body too slow"))

(* §A4.5: a share manifest may be written on a read-only route. *)
let writable route k =
  if route.read_only && not (Key.under Key.shares k) then
    answer (text 403 "read-only domain")

(* §A6, failure-model §7.4: permanent kinds are 409 with their name, the
   backend's own throttling 503, the rest 500. *)
let store_failure t (f : Fail.t) =
  if f.kind = Load then (
    (* The backend said later: the peer backs off instead of counting a
       failure of this link. *)
    count t "busy";
    Log.info "http-proxy: %s" f.reason;
    text 503 f.reason)
  else if Fail.retryable f.kind || f.kind = Unexplained || f.kind = Deadline
  then (
    count t "error";
    Log.err "http-proxy: %s" f.reason;
    text 500 f.reason)
  else (
    Log.info "http-proxy: %s" f.reason;
    let body =
      match f.kind with
        | Missing_chunks l -> String.concat "\n" ("missing chunks" :: l) ^ "\n"
        | _ -> f.reason ^ "\n"
    in
    {
      Server.status = 409;
      headers =
        [
          ("content-type", "text/plain; charset=utf-8");
          ("x-tsync-kind", Option.value ~default:"other" (Fail.wire_kind f.kind));
        ];
      body = String body;
    })

(* §A8: decided from listed sizes before any body is read. *)
let children route prefixes =
  let rec go taken total acc = function
    | [] -> List.rev acc
    | p :: rest ->
        let listing = route.store.list_prefix p in
        let children =
          List.filter
            (fun (e : Store.entry) ->
              Key.is_child_of ~namespace:p e.key
              && not (Key.is_internal_leaf (Key.leaf e.key)))
            listing
        in
        let size =
          List.fold_left (fun n (e : Store.entry) -> n + e.size) 0 children
        in
        if size > W.bulk_answer_budget then go taken total acc rest
        else if taken && total + size > W.bulk_answer_budget then List.rev acc
        else (
          let bodies =
            Rt.map_bounded ~width:8
              (fun (e : Store.entry) -> (e.key, route.store.get_opt e.key))
              children
          in
          go true (total + size)
            ({ Store.prefix = p; listing; bodies } :: acc)
            rest)
  in
  go false 0 [] prefixes

let execute t route op body =
  let s = route.store in
  let bs = Bigstring.of_string in
  match op with
    | Get k -> (
        match s.get_opt k with
          | Some b -> { Server.status = 200; headers = []; body = Bigstring b }
          | None -> empty 404)
    | Range (k, o, l) -> (
        match s.get_range k o l with
          | Some b -> { Server.status = 200; headers = []; body = Bigstring b }
          | None -> empty 404)
    | Head k -> (
        match s.head_opt k with
          | Some e ->
              {
                Server.status = 200;
                headers =
                  [
                    ("x-tsync-size", string_of_int e.size);
                    ( "x-tsync-last-modified",
                      Printf.sprintf "%.6f" e.last_modified );
                  ]
                  @ Option.fold ~none:[]
                      ~some:(fun t -> [("x-tsync-etag", t)])
                      e.etag
                  @ Option.fold ~none:[]
                      ~some:(fun c ->
                        [("x-tsync-checksum", Checksum.to_string c)])
                      e.checksum;
                body = Empty;
              }
          | None -> empty 404)
    | Put k ->
        writable route k;
        s.put k body;
        empty 200
    | Claim k -> (
        writable route k;
        match s.put_if_absent k body with
          | Won -> { Server.status = 200; headers = []; body = Bigstring body }
          | Held b -> { Server.status = 200; headers = []; body = Bigstring b })
    | Put_if_unchanged (k, etag) -> (
        writable route k;
        let expected =
          Option.map
            (fun etag ->
              {
                Store.key = k;
                size = 0;
                last_modified = 0.;
                etag = Some etag;
                checksum = None;
              })
            etag
        in
        match s.put_if_unchanged k body expected with
          | Written -> empty 200
          | Changed -> empty 412)
    | Checksum (k, algo) -> (
        match s.compute_checksum k algo with
          | Some c ->
              {
                Server.status = 200;
                headers = [("content-type", "text/plain")];
                body = String (Checksum.to_string c);
              }
          | None -> empty 404)
    | Delete k ->
        writable route k;
        if s.delete k then empty 200 else empty 204
    | Watch (k, last_seen, wait) ->
        if not (Key.equal k (Key.cursor route.domain)) then bad_request t;
        let status =
          match
            Watch_gates.wait t.gates ~route:route.name ~store:s k ~last_seen
              ~wait
          with
            | `Changed -> 200
            | `Unchanged -> 204
        in
        { Server.status; headers = [("x-tsync-watched", "1")]; body = Empty }
    | Get_multi ->
        let keys = List.map Key.v (bulk_names t body) in
        let bodies = Rt.map_bounded ~width:8 s.get_opt keys in
        {
          Server.status = 200;
          headers = [];
          body = Bigstring (W.encode_bodies bodies);
        }
    | Children_multi ->
        let prefixes = List.map Key.prefix (bulk_names t body) in
        if List.length prefixes > W.bulk_folders_max then bad_request t;
        {
          Server.status = 200;
          headers = [];
          body = Bigstring (W.encode_folders (children route prefixes));
        }
    | Delete_multi ->
        let keys = List.map Key.v (bulk_names t body) in
        if route.read_only then answer (text 403 "read-only domain");
        s.delete_multi keys;
        empty 200
    | Copy (src, dst) ->
        writable route dst;
        s.copy src dst;
        empty 200
    | List (p, max_keys) ->
        let entries =
          (if max_keys = Some 0 then [] else s.list_prefix ?max_keys p)
          |> List.filter (fun (e : Store.entry) ->
              not (is_manifest_name (Key.to_string e.key)))
        in
        {
          Server.status = 200;
          headers = [("content-type", "application/json")];
          body = Bigstring (bs (W.listing_to_json entries));
        }
    | List_key k ->
        {
          Server.status = 200;
          headers = [("content-type", "application/json")];
          body =
            Bigstring (bs (W.listing_to_json (Option.to_list (s.head_opt k))));
        }
    | Share_url p ->
        if route.share <> None then json (`Assoc [("self", `Bool true)])
        else (
          match (s.capabilities p).share_url with
            | Some u -> json (`Assoc [("url", `String u)])
            | None -> text 404 "no share endpoint")
    | Chunk_size _ -> (
        match route.chunk_size with
          | Some n -> json (`Assoc [("chunkSize", `Int n)])
          | None -> text 404 "no chunk size")
    | Max_concurrency _ -> json (`Assoc [("maxConcurrency", `Int t.bound)])
    | Verified p ->
        json (`Assoc [("verified", `Bool (s.capabilities p).verified)])

(* §A12: bytes clients wrote in request bodies and read in answers, per route
   and for the whole listener. *)
let count_bytes counters ~written (response : Server.response) =
  let add get n =
    List.iter (fun c -> ignore (Atomic.fetch_and_add (get c) n)) counters
  in
  add (fun c -> c.written) written;
  match response.body with
    | Empty -> response
    | String s ->
        add (fun c -> c.read) (String.length s);
        response
    | Bigstring b ->
        add (fun c -> c.read) (Bigstring.length b);
        response
    | Stream s ->
        {
          response with
          body =
            Stream
              {
                s with
                write =
                  (fun write ->
                    s.write (fun chunk ->
                        add (fun c -> c.read) (Bigstring.length chunk);
                        write chunk));
              };
        }

let counted t route body response =
  count_bytes
    (t.total :: Option.to_list (Hashtbl.find_opt t.traffic route.name))
    ~written:(Bigstring.length body) response

let verified_routes t (r : Server.request) params =
  if not (fresh r) then []
  else
    List.filter
      (fun route -> verifies r params Bigstring.empty route.secret)
      t.routes

let presented t route : Tsync_status.Status_report.presented =
  let traffic = Hashtbl.find_opt t.traffic route.name in
  {
    domain = route.name;
    frontend =
      {
        kind = "http-proxy";
        pid = Some (Unix.getpid ());
        mount = None;
        port =
          Option.map (fun (l : Proxy_options.listener) -> l.port) t.listener;
        open_handles = None;
        bytes_read = Option.map (fun c -> Atomic.get c.read) traffic;
        bytes_written = Option.map (fun c -> Atomic.get c.written) traffic;
        shared = true;
        read_only = Some route.read_only;
        shares = Some (route.share <> None);
        unanswered = false;
      };
  }

module R = Tsync_status.Status_report

let listener_report t : R.listener =
  {
    port = Option.map (fun (l : Proxy_options.listener) -> l.port) t.listener;
    tls = (match t.listener with Some l -> l.tls <> None | None -> false);
    in_flight = Atomic.get t.in_flight;
    data_in_flight = Atomic.get t.pending;
    bytes_read = Atomic.get t.total.read;
    bytes_written = Atomic.get t.total.written;
    requests =
      List.map
        (fun n -> (n, Atomic.get (Hashtbl.find t.tallies n)))
        (List.sort compare tally_names);
  }

let self_report t routes =
  Tsync_status.Self_report.self ~listener:(listener_report t)
    ~role:"store-server"
    ~serves:(List.map (fun r -> r.name) routes)
    ()

(* §A10: each route's owner answers for its domain within the collector's
   deadline, and this listener's entry joins each section; a silent owner is
   reported unanswered. *)
let collect t ~arg routes =
  let asked =
    Rt.map_concurrently
      (fun route ->
        ( route,
          match
            Tsync_owner.Protocol.call ~timeout:Tsync_ipc.Ipc.request_deadline
              ~domain:route.name
              (Tsync_config.Paths.owner_socket route.domain)
              (Stats ("frontend" :: arg))
          with
            | (a : R.answer) -> Ok a
            | exception e -> Error (Fail.classify e).reason ))
      routes
  in
  let domains =
    R.with_presented
      (R.answered (List.map (fun (route, a) -> (route.name, a)) asked))
      (List.map (presented t) routes)
  in
  let owners =
    List.map
      (fun (route, a) ->
        match a with
          | Ok (a : R.answer) ->
              {
                R.role = "owner";
                pid = Some a.self.server.pid;
                serves = [route.name];
                error = None;
                self = Some a.self;
              }
          | Error e ->
              {
                R.role = "owner";
                pid = None;
                serves = [route.name];
                error = Some e;
                self = None;
              })
      asked
  in
  (domains, owners)

(* [totals=1|exact] and [reload=1], as the status report's arguments. *)
let totals_arg params =
  match List.assoc_opt "totals" params with
    | Some "exact" ->
        "totals" :: "exact"
        ::
        (if List.assoc_opt "reload" params = Some "1" then ["reload"] else [])
    | Some "1" ->
        "totals"
        ::
        (if List.assoc_opt "reload" params = Some "1" then ["reload"] else [])
    | _ -> []

let listener_endpoint t (r : Server.request) params =
  match (r.meth, r.path) with
    | "GET", ("/" | "/index.html") ->
        {
          Server.status = 200;
          headers =
            [
              ("content-type", "text/html; charset=utf-8");
              ("x-content-type-options", "nosniff");
              ("referrer-policy", "no-referrer");
              ("content-security-policy", "frame-ancestors 'none'");
              ("cache-control", "no-store");
            ];
          body = String Status_page.html;
        }
    | "GET", "/domains" -> (
        count t "domains";
        match verified_routes t r params with
          | [] -> unauthorized t
          | routes ->
              json
                (`Assoc
                   [
                     ( "domains",
                       `List
                         (List.map
                            (fun route ->
                              `Assoc
                                [
                                  ("name", `String route.name);
                                  ("readOnly", `Bool route.read_only);
                                ])
                            routes) );
                   ]))
    | "GET", ("/stats" | "/api/v1/stats") -> (
        count t "stats";
        match verified_routes t r params with
          | [] -> unauthorized t
          | routes ->
              let domains, owners = collect t ~arg:(totals_arg params) routes in
              let self = self_report t routes in
              let machine : R.machine =
                {
                  host = Unix.gethostname ();
                  domains;
                  processes =
                    {
                      role = "store-server";
                      pid = Some self.server.pid;
                      serves = self.server.serves;
                      error = None;
                      self = Some self;
                    }
                    :: owners;
                  uplinks = [];
                  jobs = [];
                  warnings = [];
                }
              in
              if r.path = "/stats" then
                text 200
                  (Tsync_status.Status_text.render ~now:(Unix.gettimeofday ())
                     machine)
              else json (R.machine_to_yojson machine))
    | _ -> raise Not_found

(* §A9.1: with several share-serving routes, the one whose domain the token's
   manifest names answers, else the first, so its refusal is the answer. *)
let serve_share t (r : Server.request) params rest =
  let sharing = List.filter_map (fun route -> route.share) t.routes in
  if sharing = [] then (
    count t "notFound";
    answer (text 404 "not found"));
  if r.meth <> "GET" && r.meth <> "HEAD" then
    answer (text 405 "method not allowed");
  let token, sub =
    match String.index_opt rest '/' with
      | Some i ->
          ( String.sub rest 0 i,
            String.sub rest (i + 1) (String.length rest - i - 1) )
      | None -> (rest, "")
  in
  let share =
    match sharing with
      | [s] -> s
      | first :: _ -> (
          match
            List.find_opt (fun s -> Share_server.claims s token) sharing
          with
            | Some s -> s
            | None -> first)
      | [] -> assert false
  in
  count t "share";
  if not (Rt.Semaphore.try_acquire t.share_slots) then (
    count t "busy";
    answer (text 503 "busy"));
  let max_zip_members =
    match t.listener with Some l -> l.max_zip_members | None -> 100_000
  in
  match
    Share_server.handle share ~max_zip_members r ~token ~sub params
    |> count_bytes [t.total] ~written:0
  with
    | { body = Stream s; _ } as response ->
        {
          response with
          body =
            Stream
              {
                s with
                finally =
                  (fun () ->
                    Fun.protect
                      ~finally:(fun () -> Rt.Semaphore.release t.share_slots)
                      s.finally);
              };
        }
    | response ->
        Rt.Semaphore.release t.share_slots;
        response
    | exception e ->
        Rt.Semaphore.release t.share_slots;
        raise e

(* The wire's processing order (backends/http-proxy §6.1). *)
let handle t (r : Server.request) read_body =
  Atomic.incr t.in_flight;
  Fun.protect ~finally:(fun () -> Atomic.decr t.in_flight) @@ fun () ->
  try
    if String.starts_with ~prefix:"/s/" r.path then
      serve_share t r
        (Option.value ~default:[] (W.parse_query r.query))
        (String.sub r.path 3 (String.length r.path - 3))
    else (
      let params =
        match W.parse_query r.query with Some p -> p | None -> bad_request t
      in
      match listener_endpoint t r params with
        | response -> response
        | exception Not_found ->
            let op = parse_op t r params in
            count t (tally op);
            let limit = body_limit t op in
            (match r.body_length with
              | `Length n when n > limit && limit > 0 ->
                  count t "tooLarge";
                  answer (text 413 "too large")
              | `Length n when n > 0 && limit = 0 -> bad_request t
              | _ -> ());
            if not (fresh r) then unauthorized t;
            let names = key_names op in
            let candidates body names =
              match names with
                | first :: _ when in_share_space first ->
                    share_candidates t op body names
                | _ -> Option.to_list (route_for t names)
            in
            let authorised body names =
              match
                List.find_opt
                  (fun route -> verifies r params body route.secret)
                  (candidates body names)
              with
                | None -> unauthorized t
                | Some route -> route
            in
            (* The body is read and its signature checked before a data slot
               is taken, so an unsigned body cannot hold one while it drips. *)
            let route, body =
              match op with
                | Get_multi | Children_multi | Delete_multi ->
                    let body = read_within t r read_body limit in
                    (authorised body (bulk_names t body), body)
                | _ ->
                    (match names with
                      | first :: _ when in_share_space first -> ()
                      | _ -> if route_for t names = None then unauthorized t);
                    let body = read_within t r read_body limit in
                    (authorised body names, body)
            in
            let go () =
              try counted t route body (execute t route op body)
              with Fail.E f -> store_failure t f
            in
            if is_data op then admitted t go else go ())
  with Answer response -> response

let owner_poke (d : Domain_name.t) () =
  Tsync_ipc.Ipc.advisory
    (Tsync_config.Paths.owner_socket d)
    (`Assoc
       [
         ("action", `String "poll");
         ("domain", `String (Domain_name.to_string d));
       ])

(* §A11: with [frontend], its own entries for the route named by [domain], or
   every route; otherwise, and for [status], the full report over every route. *)
let control t stop req =
  let module P = Tsync_owner.Protocol in
  let routes =
    match Tsync_ipc.Ipc.field req "domain" with
      | Some d when List.exists (fun r -> r.name = d) t.routes ->
          List.filter (fun r -> r.name = d) t.routes
      | _ -> t.routes
  in
  let own () : R.answer =
    {
      domains = [];
      presented = List.map (presented t) routes;
      self = self_report t t.routes;
    }
  and full arg : R.answer =
    {
      domains = fst (collect t ~arg t.routes);
      presented = [];
      self = self_report t t.routes;
    }
  in
  let answer : type a. a P.request -> a = function
    | Ping -> ()
    | Stop -> (stop () : unit)
    | Stats arg when List.mem "frontend" arg -> own ()
    | Stats arg -> full arg
    | r -> Fail.invalid "unknown action: %s" (P.action r)
  in
  let reply =
    match Tsync_ipc.Ipc.field req "action" with
      | Some "status" -> P.encode_reply (Stats []) (full ["totals"])
      | _ -> (
          match P.decode req with
            | Request r -> (
                match answer r with
                  | reply -> P.encode_reply r reply
                  | exception e -> Tsync_ipc.Ipc.failure (Fail.classify e))
            | exception e -> Tsync_ipc.Ipc.failure (Fail.classify e))
  in
  Tsync_ipc.Ipc.Reply reply

let addresses (l : Proxy_options.listener) =
  List.map
    (fun a ->
      match Unix.inet_addr_of_string a with
        | addr -> Unix.ADDR_INET (addr, l.port)
        | exception Failure _ ->
            raise
              (Tsync_config.Config.Invalid
                 (Printf.sprintf "http-proxy: bad bind address %S" a)))
    l.binds

let run config =
  match Proxy_options.resolve config with
    | None ->
        Log.info "http-proxy: no domain lists the frontend";
        0
    | Some (listener, bindings) -> (
        let tls =
          Option.map
            (fun (certificate, key) ->
              Tsync_http.Transport.server_tls ~certificate ~key)
            listener.tls
        in
        let routes =
          List.map
            (fun (b : Proxy_options.binding) ->
              let domain =
                Tsync_domain.Domain.build ~owner:false
                  ~poke:(owner_poke b.domain.name) config b.domain
              in
              {
                name = Domain_name.to_string b.domain.name;
                domain = b.domain.name;
                secret = b.secret;
                read_only = b.read_only;
                chunk_size = b.domain.chunk_size;
                store = Tsync_domain.Domain.store domain;
                share =
                  (if b.shares then
                     Some
                       (Share_server.of_context
                          (Tsync_domain.Domain.context domain))
                   else None);
              })
            bindings
        in
        let t =
          create ?max_concurrent:listener.max_concurrent ~listener routes
        in
        let ctl =
          Tsync_ipc.Ipc.serve
            ~path:(Tsync_config.Paths.store_server_socket ())
            (control t Stop.request)
        in
        (* Lesson 8: the control socket and the listeners close on every
           path, a stop or a failure. *)
        Fun.protect ~finally:(fun () -> Tsync_ipc.Ipc.close ctl) @@ fun () ->
        match
          Server.serve ~limits:listener.limits ?tls (addresses listener)
            (handle t)
        with
          | exception e ->
              Log.err "http-proxy: cannot listen on port %d: %s" listener.port
                (Printexc.to_string e);
              1
          | server ->
              Fun.protect ~finally:(fun () -> Server.close server) @@ fun () ->
              Log.info "http-proxy: serving %s on port %d%s"
                (String.concat ", " (List.map (fun r -> r.name) routes))
                listener.port
                (if tls = None then "" else " (TLS)");
              Stop.wait ();
              0)
