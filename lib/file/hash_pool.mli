(** Run [f x] on a worker domain from the shared hashing pool, returning an Lwt
    promise. Used to hash file chunks in parallel with the lock-releasing
    Bigarray hash. *)
val detach : ('a -> 'b) -> 'a -> 'b Lwt.t
