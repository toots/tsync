open Tsync_core
module Dsa = Mirage_crypto_ec.P256.Dsa

type options = {
  key : string;
  key_id : string;
  team_id : string;
  topic : string;
}

type registration = {
  client : string;
  token : string;
  environment : [ `Development | `Production ];
  fp_domain : string;
  registered : float;
}

type params = {
  coalesce : float;
  max_age : float;
  auth_renewal : float;
  apns : [ `Development | `Production ] -> string;
}

let default_params =
  {
    coalesce = 10.;
    max_age = 60. *. 86400.;
    auth_renewal = 30. *. 60.;
    apns =
      (function
      | `Development -> "https://api.sandbox.push.apple.com"
      | `Production -> "https://api.push.apple.com");
  }

(* Per registration: when it was last pushed, and whether a push waits for the
   end of the interval. *)
type pace = { mutable last : float; mutable waiting : bool }

type t = {
  params : params;
  options : options;
  signer : Dsa.priv;
  post : Tsync_http.Http2.post;
  count : string -> unit;
  dir : string;
  lock : Mutex.t;
  domains : (string, (string, registration) Hashtbl.t) Hashtbl.t;
  paces : (string * string, pace) Hashtbl.t;
  mutable auth : (float * string) option;  (** made at, token *)
}

let invalid fmt =
  Printf.ksprintf (fun m -> raise (Tsync_config.Config.Invalid m)) fmt

let environment_name = function
  | `Development -> "development"
  | `Production -> "production"

let environment_of = function
  | "development" -> Some `Development
  | "production" -> Some `Production
  | _ -> None

let is_lower_hex s =
  s <> ""
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let registration_json r =
  `Assoc
    [
      ("client", `String r.client);
      ("token", `String r.token);
      ("environment", `String (environment_name r.environment));
      ("domain", `String r.fp_domain);
      ("registered", `Float r.registered);
    ]

let registration_of ~now json =
  let field k = Yojson.Safe.Util.member k json in
  match
    (field "client", field "token", field "environment", field "domain")
  with
    | `String client, `String token, `String environment, `String fp_domain
      when String.length client = 32
           && is_lower_hex client && is_lower_hex token && fp_domain <> "" -> (
        match environment_of environment with
          | Some environment ->
              let registered =
                match field "registered" with
                  | `Float f -> f
                  | `Int n -> float_of_int n
                  | _ -> now
              in
              Some { client; token; environment; fp_domain; registered }
          | None -> None)
    | _ -> None

let parse_registration ~now body =
  match Yojson.Safe.from_string body with
    | `Assoc _ as json -> (
        match registration_of ~now json with
          | Some r -> Some { r with registered = now }
          | None -> None)
    | _ | (exception Yojson.Json_error _) -> None

let file t domain = Filename.concat t.dir (domain ^ ".json")

let save t domain clients =
  Fs.mkdir_p ~perm:0o700 t.dir;
  let all =
    Hashtbl.fold (fun _ r acc -> registration_json r :: acc) clients []
  in
  Fs.durable_replace ~perm:0o600 (file t domain)
    (Yojson.Safe.to_string (`List all))

let load t domain =
  let clients = Hashtbl.create 4 in
  (match Fs.read_file_opt (file t domain) with
    | None -> ()
    | Some text -> (
        match Yojson.Safe.from_string text with
          | `List items ->
              List.iter
                (fun j ->
                  match registration_of ~now:(Unix.gettimeofday ()) j with
                    | Some r -> Hashtbl.replace clients r.client r
                    | None -> ())
                items
          | _ | (exception Yojson.Json_error _) ->
              Log.warn "push: %s is unreadable; its registrations are lost"
                (file t domain)));
  Hashtbl.replace t.domains domain clients

let read_key path =
  match Unix.stat path with
    | exception Unix.Unix_error (e, _, _) ->
        invalid "http-proxy: push_key %s: %s" path (Unix.error_message e)
    | st when st.st_perm land 0o077 <> 0 ->
        invalid "http-proxy: push_key %s is readable by others than its owner"
          path
    | _ -> (
        match X509.Private_key.decode_pem (Fs.read_file path) with
          | Ok (`P256 key) -> key
          | Ok _ -> invalid "http-proxy: push_key %s is not a P-256 key" path
          | Error (`Msg m) -> invalid "http-proxy: push_key %s: %s" path m)

let create ?(params = default_params) ~count ~dir options domains =
  let post =
    match Tsync_http.Http2.implementation () with
      | Some (_, post) -> post
      | None ->
          invalid
            "http-proxy: push_key is set but this build cannot push \
             (build-info says push: none)"
  in
  let t =
    {
      params;
      options;
      signer = read_key options.key;
      post;
      count;
      dir;
      lock = Mutex.create ();
      domains = Hashtbl.create 4;
      paces = Hashtbl.create 16;
      auth = None;
    }
  in
  List.iter (fun d -> load t (Domain_name.to_string d)) domains;
  t

(* The signature's blinding draws from it. *)
let rng = lazy (Mirage_crypto_rng_unix.use_default ())
let b64url = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let jwt t ~iat =
  let header =
    b64url
      (Yojson.Safe.to_string
         (`Assoc [("alg", `String "ES256"); ("kid", `String t.options.key_id)]))
  in
  let claims =
    b64url
      (Yojson.Safe.to_string
         (`Assoc [("iss", `String t.options.team_id); ("iat", `Int iat)]))
  in
  let input = header ^ "." ^ claims in
  Lazy.force rng;
  let r, s =
    Dsa.sign ~key:t.signer Digestif.SHA256.(to_raw_string (digest_string input))
  in
  input ^ "." ^ b64url (r ^ s)

let bearer t =
  Mutex.protect t.lock @@ fun () ->
  let now = Unix.gettimeofday () in
  match t.auth with
    | Some (made, token) when now -. made < t.params.auth_renewal -> token
    | _ ->
        let token = jwt t ~iat:(int_of_float now) in
        t.auth <- Some (now, token);
        token

let clients t domain =
  match Hashtbl.find_opt t.domains domain with
    | Some c -> c
    | None ->
        let c = Hashtbl.create 4 in
        Hashtbl.replace t.domains domain c;
        c

let register t domain r =
  let domain = Domain_name.to_string domain in
  Mutex.protect t.lock @@ fun () ->
  let c = clients t domain in
  Hashtbl.replace c r.client r;
  save t domain c

let registrations t domain =
  Mutex.protect t.lock @@ fun () ->
  Hashtbl.fold
    (fun _ r acc -> r :: acc)
    (clients t (Domain_name.to_string domain))
    []

let drop t domain client why =
  Mutex.protect t.lock (fun () ->
      let c = clients t domain in
      if Hashtbl.mem c client then (
        Hashtbl.remove c client;
        save t domain c));
  t.count "pushDropped";
  Log.info "push: %s: dropped the registration of %s (%s)" domain client why

(* APNs answers a failure as {"reason": …}. *)
let reason body =
  match Yojson.Safe.from_string body with
    | `Assoc l -> (
        match List.assoc_opt "reason" l with Some (`String r) -> r | _ -> body)
    | _ | (exception Yojson.Json_error _) -> body

let send t domain (r : registration) =
  let url = t.params.apns r.environment ^ "/3/device/" ^ r.token in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ( "container-identifier",
             `String "NSFileProviderWorkingSetContainerItemIdentifier" );
           ("domain", `String r.fp_domain);
         ])
  in
  match
    t.post ~url
      ~headers:
        [
          ("apns-push-type", "fileprovider");
          ("apns-topic", t.options.topic);
          ("authorization", "bearer " ^ bearer t);
        ]
      body
  with
    | { status = 200; _ } -> t.count "pushSent"
    | { status = 410; _ } -> drop t domain r.client "APNs: the token is gone"
    | { status = 400; body } when reason body = "BadDeviceToken" ->
        drop t domain r.client "APNs: BadDeviceToken"
    | { status; body } ->
        t.count "pushFailed";
        Log.warn "push: %s: APNs answered %d to %s: %s" domain status r.client
          (reason body)
    | exception Fail.E f ->
        t.count "pushFailed";
        Log.warn "push: %s: %s" domain f.reason

(* §A4.7: at most one push per registration every [coalesce]; one due inside
   the interval is sent once, at its end. *)
let due t domain (r : registration) =
  let now = Rt.now () in
  let send_after delay =
    Rt.spawn ~name:"push" (fun () ->
        if delay > 0. then Rt.sleep delay;
        Mutex.protect t.lock (fun () ->
            let p = Hashtbl.find t.paces (domain, r.client) in
            p.last <- Rt.now ();
            p.waiting <- false);
        send t domain r)
  in
  Mutex.protect t.lock (fun () ->
      match Hashtbl.find_opt t.paces (domain, r.client) with
        | None ->
            Hashtbl.replace t.paces (domain, r.client)
              { last = now; waiting = true };
            Some 0.
        | Some { waiting = true; _ } -> None
        | Some p ->
            p.waiting <- true;
            Some (Float.max 0. (p.last +. t.params.coalesce -. now)))
  |> Option.iter send_after

let changed t domain ~author =
  let domain = Domain_name.to_string domain in
  let now = Unix.gettimeofday () in
  let live, stale =
    Mutex.protect t.lock (fun () ->
        Hashtbl.fold
          (fun _ r (live, stale) ->
            if now -. r.registered > t.params.max_age then (live, r :: stale)
            else if r.client = author then (live, stale)
            else (r :: live, stale))
          (clients t domain) ([], []))
  in
  List.iter (fun r -> drop t domain r.client "not renewed") stale;
  List.iter (due t domain) live
