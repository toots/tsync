(** A vault's icon from any image (spec extensions/vault.md §8.1). A client
    converts before it sends; the owner accepts only the stored form. *)

(** A converter in this process, set by whatever links the FFmpeg bindings: the
    image at a path or URL, its centre square scaled to at most [max_side] and
    encoded as PNG within [max_bytes], by the deadline (a {!Rt.now} instant).
    When unset, the media helper converts. *)
val converter :
  (max_side:int -> max_bytes:int -> deadline:float -> string -> string) option
  Atomic.t

(** The converter in this process, else the media helper's when it is installed:
    raises {!Fail.E} when the helper fails. *)
val current :
  unit ->
  (max_side:int -> max_bytes:int -> deadline:float -> string -> string) option

(** Whether this host can convert an image. *)
val available : unit -> bool
