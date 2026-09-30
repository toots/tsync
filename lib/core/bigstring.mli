(** Off-heap byte buffers, the type of every data body: the kernel pages them,
    the collector never copies them, and a mapped file is one without a copy.
    OCaml strings are for small metadata, converted at the edge. *)

type t = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

val create : int -> t
val empty : t
val length : t -> int

(** A view sharing the memory of [t]. *)
val sub : t -> off:int -> len:int -> t

val of_string : string -> t
val to_string : ?off:int -> ?len:int -> t -> string
val equal : t -> t -> bool
val blit : src:t -> src_off:int -> dst:t -> dst_off:int -> len:int -> unit
val blit_to_bytes : t -> int -> Bytes.t -> int -> int -> unit
val blit_from_bytes : Bytes.t -> int -> t -> int -> int -> unit
val concat : t list -> t
