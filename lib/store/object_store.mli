(** The object-store shell (spec backends/object-store-common.md §2): a bucket
    driver supplies a handful of verbs, the shell answers the rest of the store
    contract the same way for every bucket.

    Until the bucket-side function is confirmed (§3), a bucket claims no
    verification and queues no work. *)

open Tsync_core

(** A listed object, before its name is validated. *)
type raw_entry = {
  name : string;
  size : int;
  last_modified : float;
  etag : string option;
  checksum : Checksum.t option;
}

(** Each verb is one attempt: a transient failure raises for the ladder, a clean
    absence is [None] or [false]. *)
type verbs = {
  put : Key.t -> Bigstring.t -> unit;
  put_if_absent : Key.t -> Bigstring.t -> Store.claim;
  get_opt : Key.t -> Bigstring.t option;
  get_range : Key.t -> int -> int -> Bigstring.t option;
  head_opt : Key.t -> Store.entry option;
  delete : Key.t -> bool;
  delete_page : Key.t list -> unit;  (** at most {!page} keys *)
  copy : Key.t -> Key.t -> unit;
  list_page :
    prefix:Key.prefix ->
    token:string option ->
    max:int option ->
    raw_entry list * string option;
      (** one page and the next page's token *)
}

val page : int

(** failure-model §4.2: the kind of an HTTP status on a store request. *)
val status_failure :
  op:string -> ?retry_after:float -> ?body:string -> int -> Fail.t

(** failure-model §4.2: a per-key refusal inside an answered bulk request. *)
val per_key_failure : op:string -> code:string -> key:string -> Fail.t

val make :
  name:string -> admission:Uplink.t -> ?share_url:string -> verbs -> Store.t
