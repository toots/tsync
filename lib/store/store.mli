(** The store contract (spec 06 §3). A store is a record of operations; every
    driver and the composite of a domain's members produce one, so callers never
    learn which they face.

    Every operation fails with exactly one kind of {!Tsync_core.Fail}; "could
    not look" is never "absent". *)

open Tsync_core

type entry = {
  key : Key.t;
  size : int;
  last_modified : float;
      (** wall-clock epoch seconds, finest resolution kept *)
  etag : string option;  (** the store's version name, when it has one *)
}

type caps = {
  share_url : string option;
  chunk_size : int option;  (** recommended for new files *)
  max_concurrency : int option;
  verified : bool;
      (** every chunk this store takes is checked, by someone known to run *)
}

(** The answer to a conditional create: [Won] when the name holds exactly the
    body asked for, [Held b] when another writer's [b] holds it. *)
type claim = Won | Held of Bigstring.t

(** Upload admission (06 §6): [Wait] acquires, [Best_effort] fails CANCELLED
    rather than wait. *)
type mode = Wait | Best_effort

(** One folder of a [list_many] answer: its whole listing and a body (or
    absence) for each child object. *)
type folder = {
  prefix : Key.prefix;
  listing : entry list;
  bodies : (Key.t * Bigstring.t option) list;
}

type traffic = { uploaded : int Atomic.t; downloaded : int Atomic.t }

type t = {
  name : string;  (** for messages: the member's name *)
  put : ?mode:mode -> Key.t -> Bigstring.t -> unit;
  put_if_absent : Key.t -> Bigstring.t -> claim;
  get_opt : Key.t -> Bigstring.t option;
  get_range : Key.t -> int -> int -> Bigstring.t option;
      (** [offset], [length]: the bytes up to the end, empty past it, [None]
          when absent. *)
  head_opt : Key.t -> entry option;
  delete : Key.t -> bool;  (** whether an object was removed *)
  delete_multi : Key.t list -> unit;
      (** absent keys succeed; any other refusal fails the whole call *)
  copy : Key.t -> Key.t -> unit;
  list_prefix : ?max_keys:int -> Key.prefix -> entry list;
      (** every valid key under the prefix, recursively, in ascending order *)
  watch : Key.t -> string option -> unit;
      (** return when the key may have changed, or after at most
          {!watch_interval}; the argument is the token last seen *)
  get_many : (Key.t list -> Bigstring.t option list) option;
  list_many : (Key.prefix list -> folder list) option;
  bucket_functions : bool;
      (** requests put under [tsync/gc-jobs/] and [tsync/verify-jobs/] may be
          consumed by a bucket-side function; whether one is deployed is the
          owner's confirmation (06 §3.8) *)
  capabilities : Key.prefix -> caps;
  fast_read : bool;
  local_path : string option;
  health : Tsync_core.Health.t;
  traffic : traffic option;
}

val no_caps : caps
val new_traffic : unit -> traffic

(** [get_opt], turning a clean absence into ABSENT. *)
val get : t -> Key.t -> Bigstring.t

val watch_interval : float

(** The watch token of a body: surrounding whitespace removed. *)
val token : Bigstring.t option -> string option

(** Refuse a malformed range before any request, and send nothing for an empty
    bulk list. Every driver is wrapped in it. *)
val checked : t -> t

(** The validating boundary for a name a store listed: [None], with a warning
    once, for a name that is not a valid key. *)
val listed : string -> string -> Key.t option

val max_batch_keys : int
val max_batch_bytes : int
val max_batch_folders : int

(** Read many listed entries: native batches within the key and byte caps where
    declared, else one read each. A batch failing permanently is re-asked key by
    key. *)
val read_many : t -> entry list -> (Key.t * Bigstring.t option) list

val count_up : t -> int -> unit
val count_down : t -> int -> unit
