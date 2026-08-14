(** Asking an object store to check everything it holds.

    The bucket is the queue. A request is an empty object under
    {!Chunk_layout.verify_jobs_prefix}, one per shard, and the store's own
    object-created notification carries it to the function that already checks
    chunks — which lists that shard and runs the same per-chunk check it runs on
    an upload, then deletes the request.

    So this is only [put], and only the object stores implement
    {!Backend.S.verify_all} with it: a filesystem has no event source to deliver
    anything, and [tsync gc --verify] is its sweep. *)

(** Queue one request per shard. Answers how many, which is work started rather
    than work done: what came of it is read afterwards by listing
    {!Chunk_layout.corrupted_prefix}. *)
val queue :
  put:(key:string -> data:string -> unit -> unit Lwt.t) ->
  chunk_prefix:string ->
  int Lwt.t
