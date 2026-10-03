(** The http-proxy wire (spec backends/http-proxy.md §3–§5), shared by the
    client driver and the store server so neither spells it on its own. *)

open Tsync_core

val max_clock_skew : float
val bulk_keys_max : int
val bulk_folders_max : int
val bulk_answer_budget : int
val watch_max : float

(** §3.2: the query as a client must send it, [key=value] joined by [&], every
    byte outside the allowed sets as upper-case [%XX]. *)
val canonical_query : (string * string) list -> string

(** A server's parse of a raw query, in received order; [None] for a malformed
    escape, a part without [=], or a repeated name. *)
val parse_query : string -> (string * string) list option

(** §3.1: [x-tsync-signature] for a request, lower-case hex. *)
val signature :
  secret:string ->
  meth:string ->
  target:string ->
  timestamp:string ->
  Bigstring.t ->
  string

(** The two headers a client adds, the timestamp from the wall clock. *)
val sign :
  secret:string ->
  meth:string ->
  target:string ->
  Bigstring.t ->
  (string * string) list

(** §3.3: 1 to 15 digits within {!max_clock_skew} of [now]. *)
val fresh : now:float -> string -> bool

(** Constant-time comparison against the recomputed signature. *)
val verify :
  secret:string ->
  meth:string ->
  target:string ->
  timestamp:string ->
  signature:string ->
  Bigstring.t ->
  bool

(** §4.1: a key in a path, base64url without padding. *)
val encode_key : Key.t -> string

val decode_key : string -> Key.t option
val listing_to_json : Tsync_store.Store.entry list -> string

(** [listing_to_json]'s text, handed to [write] in pieces. *)
val listing_pieces : Tsync_store.Store.entry list -> (string -> unit) -> unit

(** CORRUPT for anything that is not an array of entries. *)
val listing_of_json : string -> Tsync_store.Store.entry list

(** §4.3: get-multi frames, one per key in request order. *)
val encode_bodies : Bigstring.t option list -> Bigstring.t

(** Sent with a get-multi request by a client that takes an answer to the first
    keys only and asks again for the rest (§8.3). *)
val partial_header : string

(** The bodies of the first keys asked, in order: at least one, at most [count].
    CORRUPT for none, or for more. *)
val decode_bodies : count:int -> Bigstring.t -> Bigstring.t option list

val encode_folders : Tsync_store.Store.folder list -> Bigstring.t

(** CORRUPT for a folder not asked for or a child outside its folder. *)
val decode_folders :
  asked:Key.prefix list -> Bigstring.t -> Tsync_store.Store.folder list
