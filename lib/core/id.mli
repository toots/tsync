(** Random hex ids. *)

(** 16 hex characters from a PRNG seeded from the kernel once per process, a
    forked child included. For ids that only need to not collide — staged body
    names, trash entries — and are minted often enough that reading the kernel
    for each would show. *)
val short : unit -> string

(** [n] bytes straight from [/dev/urandom], hex encoded. For ids whose
    unguessability is load-bearing: share tokens, the client uuid. Raises if
    [/dev/urandom] cannot be read rather than falling back to something weaker.
*)
val token : int -> string
