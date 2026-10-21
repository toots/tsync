(** A vault's icon from any image (spec extensions/vault.md §8.1): set when the
    build links the FFmpeg bindings, by the library that wraps them. A client
    converts before it sends; the owner accepts only the stored form. *)

(** The image at a path or URL, its centre square scaled to at most [max_side]
    and encoded as PNG within [max_bytes], by the deadline (a {!Rt.now}
    instant). *)
val converter :
  (max_side:int -> max_bytes:int -> deadline:float -> string -> string) option
  Atomic.t

(** Whether this build can convert an image. *)
val available : unit -> bool
