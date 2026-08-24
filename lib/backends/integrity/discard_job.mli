(** Asking an object store to drop chunks a collection found unreferenced.

    The bucket is the queue, as it is for {!Verifier}: a request written under
    {!Chunk_layout.gc_jobs_prefix} reaches the function through the store's own
    object-created notification, and that function deletes the keys, the markers
    naming them, and then the request itself.

    Where a verify request is empty and names its shard, this one carries the
    keys. A copy has no from-space to be pointed at — only the main is renamed —
    so which chunks are garbage is knowable nowhere but on the main.

    So this is only [put], and only the object stores implement
    {!Backend.S.discard} with it. A filesystem and an http-proxy peer have
    nothing on their side to wake and delete in the call instead.

    [queue] returns once the request is durably stored, which is what lets the
    collection go on to discard the main's own copy: the request outliving the
    collector is the whole of what that ordering rests on. *)
val queue :
  put:(key:Stored_key.t -> data:string -> unit -> unit Lwt.t) ->
  chunk_prefix:string ->
  run:string ->
  name:string ->
  keys:Stored_key.t list ->
  unit ->
  unit Lwt.t

(** The body, shared so the two stores that write one, and whatever reads one
    back, cannot spell it differently. *)
val encode : Stored_key.t list -> string

val decode : string -> Stored_key.t list
