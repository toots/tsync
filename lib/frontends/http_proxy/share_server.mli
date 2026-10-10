(** The share server (spec frontends/http-proxy.md §A9, security-model §6):
    public, expiring links to a file or a folder of one domain, served from its
    store and never from any local state. *)

open Tsync_core

type t

val of_context : (module Tsync_remote.Context.S) -> t

(** Whether [token] loads as a valid, live share of this domain (§A9.1). *)
val claims : t -> string -> bool

(** The manifest's domain, when the body parses as one. *)
val manifest_domain : string -> Domain_name.t option

(** [self] is where a thumbnailer reaches this listener's own share links; [tls]
    picks the scheme of the page's absolute URLs when no proxy names one. *)
val handle :
  ?self:string ->
  tls:bool ->
  max_zip_members:int ->
  token:string ->
  sub:string ->
  t ->
  Tsync_http.Server.request ->
  (string * string) list ->
  Tsync_http.Server.response

(**/**)

val parse_range :
  int -> string option -> [ `Whole | `Unsatisfiable | `Range of int * int ]

val disposition : string -> string -> string
val media : string -> bool
val fill : string -> (string * string) list -> string
val script_json : Yojson.Safe.t -> string
