(** XXH3-64 (xxHash 0.8) and the dual digest of spec 01 §3. *)

type bigstring = Bigstring.t

val string : ?seed:int64 -> string -> int64
val bigstring : ?seed:int64 -> ?off:int -> ?len:int -> bigstring -> int64

(** Lowercase, zero-padded, 16 characters. *)
val hex16 : int64 -> string

(** [hex16 (seed 0) ^ "-" ^ hex16 (seed 1)]: chunk keys, leaf hashes, digests.
*)
val dual : string -> string

val dual_bigstring : ?off:int -> ?len:int -> bigstring -> string

(** Streaming dual digest; equal to one-shot hashing for every split. *)
type dual_state

val dual_create : unit -> dual_state
val dual_update_string : dual_state -> string -> int -> int -> unit
val dual_update_bigstring : dual_state -> bigstring -> int -> int -> unit
val dual_digest : dual_state -> string
