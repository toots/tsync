(* What queueing the requests needs of a pool. *)

module Over (Io : Io.S) (Bounded : Bounded.S with type 'a io := 'a Io.t) = struct
  let ( let+ ) x f = Io.map f x

  (* One request per shard, and the store's own object-created notification is what
     delivers them: a bucket that already calls a function on every new chunk will
     call it on these too, so a whole-store check needs no queue service, no second
     credential, and no second code path — the function it wakes runs the same
     per-chunk check it runs on an upload.

     Every shard, not the ones that exist: a client cannot cheaply ask an object
     store which prefixes are populated, and asking would cost more listings than
     the empty jobs cost invocations. An empty shard is one listing that finds
     nothing and a job object deleted. *)

  (* Requests in flight, unrelated to {!Chunk_layout.fanout}: wide enough that
     queueing is seconds rather than minutes, narrow enough not to be the reason a
     bucket starts throttling. *)
  let fanout = 32

  (* Not batched: both stores have a bulk delete and neither has a bulk put, so
     this is one round trip per shard, [fanout] of them at a time. *)
  let queue ?(on_progress = fun ~done_:_ ~total:_ -> ()) ~put ~chunk_prefix () =
    let module L = Chunk_layout.Make (struct
      let chunk_prefix = chunk_prefix
    end) in
    let slots = Bounded.create ~max:fanout () in
    let shards = List.init Chunk_layout.shards Chunk_layout.shard_name in
    let total = List.length shards in
    let done_ = ref 0 in
    let+ () =
      Io.iter_p
        (fun shard ->
          Bounded.use slots (fun () ->
              let+ () = put ~key:(L.verify_job_key shard) ~data:"" () in
              incr done_;
              on_progress ~done_:!done_ ~total))
        shards
    in
    total
end
