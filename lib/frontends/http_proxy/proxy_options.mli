(** The http-proxy options of every domain that lists the frontend (spec
    frontends/http-proxy.md §A3): one listener shared by all, and per-domain
    settings that inherit a value every binding agrees on. A violation raises
    {!Tsync_config.Config.Invalid} naming the option. *)

open Tsync_config

type listener = {
  port : int;
  binds : string list;  (** addresses; loopback only without TLS unless named *)
  tls : (string * string) option;  (** certificate and key *)
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

(** [None] when no domain lists the frontend. *)
val resolve : Config.t -> (listener * binding list) option
