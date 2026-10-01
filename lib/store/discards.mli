(** One copy's queued collection deletions (spec algorithms/replication.md §4.8,
    gc.md §5.7): the discard requests its owner wrote and has not seen consumed,
    in a durable log beside the copy's job log, and the owner's confirmation
    that a bucket function consumes them (object-store-common §3). *)

open Tsync_core

(** One request: [keys] are full chunk keys of the collected domain. *)
type pending = {
  run : string;
  shard : string;
  generation : int;
  keys : string list;
}

type t

(** [dir] is the copy's job log directory; the log is [<dir>.discards/] and the
    confirmation [<dir>.function]. *)
val open_ : dir:string -> t

(** A confirmation younger than FUNCTION_PROBE_VALIDITY (7 days). *)
val confirmed : ?now:float -> t -> bool

val confirmed_at : t -> float option
val record_confirmation : t -> at:float -> unit

(** Each pending request with its record id. *)
val pending : t -> (string * pending) list

(** Records [p] durably, merged into a pending request of the same run and
    shard, and answers the request to write. *)
val add : t -> pending -> pending

(** The request was consumed and its restore check done. *)
val remove : t -> string -> unit

val request_key : Domain_name.t -> pending -> Key.t

(** A request body: one chunk key per line (02 §2.13). *)
val body : string list -> Bigstring.t

val keys_of_body : Bigstring.t -> Key.t list
