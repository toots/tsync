open Tsync_config

type listener = {
  port : int;
  binds : string list;
  tls : (string * string) option;
  max_concurrent : int option;
  max_put_body : int;
  max_bulk_body : int;
  max_body_memory : int;
  max_share_responses : int;
  max_zip_members : int;
  limits : Tsync_http.Server.limits;
}

type binding = {
  domain : Config.domain;
  secret : string;
  shares : bool;
  read_only : bool;
}

let invalid fmt = Printf.ksprintf (fun m -> raise (Config.Invalid m)) fmt
let mib = 1024 * 1024

let present (o : Config.value option) =
  match o with Some (S "") | None -> None | v -> v

(* A listener option is set at most once across bindings. *)
let listener_value bindings name =
  match
    List.sort_uniq compare
      (List.filter_map
         (fun opts -> present (List.assoc_opt name opts))
         bindings)
  with
    | [] -> None
    | [v] -> Some v
    | _ ->
        invalid "http-proxy: %s differs between domains; the listener is shared"
          name

(* An unset secret inherits the value every binding that sets one agrees on;
   exposure (shares, readOnly) never crosses domains. *)
let inherited bindings opts name =
  match present (List.assoc_opt name opts) with
    | Some v -> Some v
    | None -> (
        match
          List.sort_uniq compare
            (List.filter_map
               (fun o -> present (List.assoc_opt name o))
               bindings)
        with
          | [v] -> Some v
          | _ -> None)

let int = function Some (Config.I n) -> Some n | _ -> None
let str = function Some (Config.S s) -> Some s | _ -> None

let float = function
  | Some (Config.F f) -> Some f
  | Some (Config.I n) -> Some (float_of_int n)
  | _ -> None

let bool = function Some (Config.B b) -> b | _ -> false

let positive name = function
  | Some n when n <= 0 -> invalid "http-proxy: %s must be positive" name
  | v -> v

let resolve (config : Config.t) =
  let bound =
    List.filter_map
      (fun (d : Config.domain) ->
        Option.map
          (fun (f : Config.frontend) -> (d, f.options))
          (Config.frontend d "http-proxy"))
      config.domains
  in
  if bound = [] then None
  else (
    let all = List.map snd bound in
    let lv name = listener_value all name in
    let tls =
      match (str (lv "ssl_certificate"), str (lv "ssl_certificate_key")) with
        | Some c, Some k -> Some (c, k)
        | None, None -> None
        | _ ->
            invalid
              "http-proxy: ssl_certificate and ssl_certificate_key go together"
    in
    let binds =
      match str (lv "bind") with
        | Some b ->
            List.filter (( <> ) "")
              (List.map String.trim (String.split_on_char ',' b))
        | None -> if tls = None then ["127.0.0.1"; "::1"] else ["0.0.0.0"; "::"]
    in
    let size name default =
      Option.value ~default (positive name (int (lv name)))
    in
    let d = Tsync_http.Server.default_limits in
    let secs name default = Option.value ~default (float (lv name)) in
    let listener =
      {
        port =
          Option.value
            ~default:(if tls = None then 80 else 443)
            (int (lv "port"));
        binds;
        tls;
        max_concurrent = positive "max_concurrent" (int (lv "max_concurrent"));
        max_put_body = size "max_put_body" (256 * mib);
        max_bulk_body = size "max_bulk_body" mib;
        max_body_memory = size "max_body_memory" (1024 * mib);
        max_share_responses = size "max_share_responses" 64;
        max_zip_members = size "max_zip_members" 100_000;
        limits =
          {
            d with
            header_timeout = secs "header_timeout" d.header_timeout;
            idle_timeout = secs "idle_timeout" d.idle_timeout;
            keepalive_timeout = secs "keepalive_timeout" d.keepalive_timeout;
            max_connections = size "max_connections" d.max_connections;
          };
      }
    in
    let bindings =
      List.map
        (fun ((dom : Config.domain), opts) ->
          let name = Tsync_core.Domain_name.to_string dom.name in
          let secret =
            match str (inherited all opts "secret") with
              | Some s -> s
              | None -> invalid "http-proxy for %s: a secret is required" name
          in
          {
            domain = dom;
            secret;
            shares = bool (present (List.assoc_opt "shares" opts));
            read_only =
              dom.read_only || bool (present (List.assoc_opt "readOnly" opts));
          })
        bound
    in
    Some (listener, bindings))
