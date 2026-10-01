(** One copy's queued collection deletions (spec algorithms/replication.md §4.8,
    gc.md §5.7): the discard requests its owner wrote and has not seen consumed,
    in a durable log beside the copy's job log. *)

open Tsync_core

(** One request: [keys] are full chunk keys of the collected domain. *)
type pending = {
  run : string;
  shard : string;
  generation : int;
  keys : string list;
}

type t

(** [dir] is the copy's job log directory; the log is [<dir>.discards/]. *)
val open_ : dir:string -> t

(** Each pending request with its record id. *)
val pending : t -> (string * pending) list

(** Merges [p] into a pending request of the same run and shard, has [write] put
    that request on the copy, then records it durably: a pending request whose
    key is absent was consumed, never not yet written. *)
val add : t -> pending -> write:(pending -> unit) -> unit

(** The request was consumed and its restore check done. *)
val remove : t -> string -> unit

val request_key : Domain_name.t -> pending -> Key.t

(** A request body: one chunk key per line (02 §2.13). *)
val body : string list -> Bigstring.t

val keys_of_body : Bigstring.t -> Key.t list
