open Lwt.Syntax

(* One request per shard, and the store's own object-created notification is what
   delivers them: a bucket that already calls a function on every new chunk will
   call it on these too, so a whole-store check needs no queue service, no second
   credential, and no second code path — the function it wakes runs the same
   per-chunk check it runs on an upload.

   Every shard, not the ones that exist: a client cannot cheaply ask an object
   store which prefixes are populated, and asking would cost more listings than
   the empty jobs cost invocations. An empty shard is one listing that finds
   nothing and a job object deleted. *)

(* Wide enough that queueing is seconds rather than minutes, narrow enough not to
   be the reason a bucket starts throttling. *)
let fanout = 32

let queue ~put ~chunk_prefix =
  let slots = Lwt_bounded.create ~max:fanout () in
  let shards = List.init Chunk_layout.shards Chunk_layout.shard_name in
  let+ () =
    Lwt_list.iter_p
      (fun shard ->
        Lwt_bounded.use slots (fun () ->
            put
              ~key:(Chunk_layout.verify_job_key ~chunk_prefix shard)
              ~data:"" ()))
      shards
  in
  List.length shards
