(** Random hex ids. *)

(** 16 hex characters from a PRNG seeded once from the kernel. For ids that only
    need to not collide — staged body names, folder ids — and are minted often
    enough that a syscall each would show. *)
val short : unit -> string

(** [n] bytes straight from [/dev/urandom], hex encoded. For ids whose
    unguessability is load-bearing: share tokens, the client uuid. Raises if
    [/dev/urandom] cannot be read rather than falling back to something weaker.
*)
val token : int -> string
