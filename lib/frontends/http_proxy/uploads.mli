(** Whole-file uploads (frontends/http-proxy §A4.8, wire §5.7): spooled to disk
    over the resumable upload draft, committed through the domain's owner on
    this host. *)

open Tsync_core

type route = {
  name : string;
  domain : Domain_name.t;
  secret : string;
  read_only : bool;
  takes : bool;  (** the domain's [uploads] option *)
  chunk : int;  (** the domain's chunk size, for the file's content id *)
  owner : string;  (** the owner socket *)
}

type t

(** [routes]: every domain the listener serves. [count] adds to a tally. [wrote]
    follows a commit that wrote the domain. *)
val create :
  dir:string ->
  count:(string -> int -> unit) ->
  wrote:(Domain_name.t -> unit) ->
  route list ->
  t

val max_upload_size : int

(** The domain takes uploads. *)
val takes : t -> Domain_name.t -> bool

(** The answer to a request under [/upload], [None] for any other path. *)
val handle : t -> Tsync_http.Server.request -> Tsync_http.Server.response option

(** Drops idle incomplete uploads and old commit records. *)
val sweep : t -> unit
