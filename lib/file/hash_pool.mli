(** Run [f x] on a worker domain from the shared hashing pool, returning an Lwt
    promise. Runs a file's whole-file chunk hash off the event loop, so
    concurrent uploads hash in parallel and the loop keeps scheduling during the
    (lock-releasing) hash. *)
val detach : ('a -> 'b) -> 'a -> 'b Lwt.t
