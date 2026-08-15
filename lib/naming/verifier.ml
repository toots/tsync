open Lwt.Syntax

(* Whether anything is checking this store, asked of the store rather than of the
   operator. The deployment writes {!Chunk_layout.verifier_key} when it creates
   the function, so the answer is a fact about what exists and not a claim
   somebody made in a config file once.

   Not memoised here: a driver holds its own, so a fresh store instance probes
   again — which is what makes it testable, and what keeps one bucket's answer
   out of another's. *)
let deployed ~head_opt ~prefix =
  Lwt.catch
    (fun () ->
      let+ found = head_opt ~key:(Chunk_layout.verifier_key ~prefix) () in
      Option.is_some found)
    (* A store we cannot reach has not told us it checks anything. *)
    (fun _ -> Lwt.return_false)

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

(* Not batched, and not for want of trying: [delete_multi] exists because both
   stores have a bulk delete, and neither has a bulk put. 4096 round trips it is,
   which is why they go out [fanout] at a time. *)
let queue ?(on_progress = fun ~done_:_ ~total:_ -> ()) ~put ~chunk_prefix () =
  let slots = Lwt_bounded.create ~max:fanout () in
  let shards = List.init Chunk_layout.shards Chunk_layout.shard_name in
  let total = List.length shards in
  let done_ = ref 0 in
  let+ () =
    Lwt_list.iter_p
      (fun shard ->
        Lwt_bounded.use slots (fun () ->
            let+ () =
              put
                ~key:(Chunk_layout.verify_job_key ~chunk_prefix shard)
                ~data:"" ()
            in
            incr done_;
            on_progress ~done_:!done_ ~total))
      shards
  in
  total
