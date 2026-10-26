(** The store server (spec frontends/http-proxy.md §A4–§A13): one listener
    re-exporting each served domain's composite store under the wire of
    backends/http-proxy.md, admission-bounded, with coalesced watches. It owns
    no domain state; deferred work its writes cause lands in the owners' logs.
*)

(** A route's [share]: [`Self] serves [/s/]; [`Member] hands out that member's
    links and takes the share space to its store (§A4.6). *)
type route = {
  name : string;
  domain : Tsync_core.Domain_name.t;
  secret : string;
  read_only : bool;
  domain_settings : Tsync_store.Store.domain_settings;
  wake : unit -> unit;
      (** asks the domain's owner on this host for a cycle: it projects the
          entries created here *)
  store : Tsync_store.Store.t;
  share :
    [ `Off | `Self of Share_server.t | `Member of Tsync_store.Composite.member ];
}

type t

(** The request pipeline over prepared routes. *)
val create :
  ?max_concurrent:int -> ?listener:Proxy_options.listener -> route list -> t

val handle :
  t ->
  Tsync_http.Server.request ->
  (limit:int -> Tsync_core.Bigstring.t) ->
  Tsync_http.Server.response

(** Serve until the process stop, then finish in-flight requests within the
    grace. Answers the exit status. *)
val run : Tsync_config.Config.t -> int
