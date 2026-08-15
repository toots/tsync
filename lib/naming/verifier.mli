(** The store-side verifier: whether one is deployed, and asking it to check
    everything.

    The bucket is the queue. A request is an empty object under
    {!Chunk_layout.verify_jobs_prefix}, one per shard, and the store's own
    object-created notification carries it to the function that already checks
    chunks — which lists that shard and runs the same per-chunk check it runs on
    an upload, then deletes the request.

    So this is only [put], and only the object stores implement
    {!Backend.S.verify_all} with it: a filesystem has no event source to deliver
    anything, and [tsync gc --verify] is its sweep. *)

(** Whether a verifier is deployed for this domain, by reading the object its
    deployment writes. Asked of the store because the alternative — asking the
    operator — is a question about infrastructure they may not have deployed,
    and a stale answer reads as a clean bill of health for a store nothing is
    checking.

    Unreachable answers [false]: a store that did not respond has not told us it
    checks anything. *)
val deployed :
  head_opt:(key:string -> unit -> Backend.file_entry option Lwt.t) ->
  prefix:string ->
  bool Lwt.t

(** Queue one request per shard. Answers how many, which is work started rather
    than work done: what came of it is read afterwards by listing
    {!Chunk_layout.corrupted_prefix}.

    Not batched — neither store has a bulk put, only a bulk delete — so this is
    one round trip per shard and [on_progress] is how a caller says so rather
    than appearing to hang. *)
val queue :
  ?on_progress:(done_:int -> total:int -> unit) ->
  put:(key:string -> data:string -> unit -> unit Lwt.t) ->
  chunk_prefix:string ->
  unit ->
  int Lwt.t
