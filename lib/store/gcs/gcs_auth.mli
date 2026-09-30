(** Service account to bearer token (spec backends/gcs.md §2): the RFC 7523
    JWT-bearer grant, one cached token per store, fresh on the monotonic clock,
    minted by one caller at a time. *)

type t

(** Parses the service-account key text; INVALID with the messages of §1.1. *)
val create : string -> t

(** A fresh token, minted when none is. *)
val token : t -> string

(** Drops the cached token if it is still [token]. *)
val invalidate : t -> string -> unit
