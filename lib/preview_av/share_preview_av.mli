(** The share preview thumbnailer and the vault icon converter on the FFmpeg
    bindings (spec frontends/http-proxy.md §A9.8, extensions/vault.md §8.1),
    which the media helper runs. *)

open Tsync_core

(** One frame of the file at [url], scaled to {!Share_preview.size} on its
    longest side and encoded as JPEG, by the deadline (a {!Rt.now} instant). *)
val thumbnail :
  kind:Share_preview.kind -> deadline:float -> string -> Bigstring.t

(** The image at a path or URL, its centre square scaled to at most [max_side]
    and encoded as PNG within [max_bytes], by the deadline. *)
val icon : max_side:int -> max_bytes:int -> deadline:float -> string -> string

(** Makes both the thumbnailer and the icon converter of this process. *)
val install : unit -> unit

(**/**)

val fit : int -> int -> int * int
