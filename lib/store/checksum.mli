(** Data-integrity checksums of stored bodies (spec 06 §2.5): what a store's
    service keeps for an object, and what any component computes from bytes it
    holds, so that two stores' copies compare without moving the object. *)

open Tsync_core

type t = private { algo : string; value : string }

(** The algorithm every component implements. *)
val md5 : string

(** [algo] is one this build computes. *)
val known : string -> bool

(** [comparable a b]: same algorithm, so equal values mean equal bodies. *)
val comparable : t -> t -> bool

(** ["<algo>:<value>"], the spelling on every wire. *)
val to_string : t -> string

(** Parses {!to_string}; [None] for an unknown algorithm or a malformed value,
    which a reader treats as no checksum. *)
val of_string : string -> t option

(** An MD5 a service reports in hex (an S3 ETag): [None] unless it is exactly 32
    hex digits. *)
val md5_of_hex : string -> t option

(** An MD5 a service reports in base64 (GCS's [md5Hash]). *)
val md5_of_base64 : string -> t option

(** Fails INVALID for an algorithm outside {!known}. *)
val of_body : string -> Bigstring.t -> t
