(** A share's preview image (spec frontends/http-proxy.md §A9.8): the JPEG a
    chat application shows in a link's card. The share operation makes one after
    a link is returned; the share server makes a missing one on demand, and both
    servers and the store server check one with {!valid}. The constants are
    [SHARE_PREVIEW_MAX_BYTES], [SHARE_PREVIEW_SIZE] (the exact longest side),
    [SHARE_PREVIEW_MIN_SIDE] and [SHARE_PREVIEW_TIMEOUT]. *)

val max_bytes : int
val size : int
val min_side : int
val timeout : float

(** A baseline or progressive 8-bit JPEG within the size rules. *)
val valid : Bigstring.t -> bool

type kind = [ `Image | `Video | `Audio ]

(** What a file of that name is to a thumbnailer, by the shared mime table;
    [None] for anything it cannot make a frame of. *)
val kind_of_name : string -> kind option

(** Set when the build links the FFmpeg bindings, by the library that wraps
    them: one frame of the file at the URL, scaled to {!size} on its longest
    side, by the deadline (a {!Rt.now} instant). *)
val thumbnailer :
  (kind:kind -> deadline:float -> string -> Bigstring.t option) option Atomic.t

(** Whether this build can make a preview image. *)
val available : unit -> bool

(** The thumbnailer's image of the file at [url], read over ranged requests,
    when it is {!valid}; [None] without a thumbnailer, on failure, or past
    {!timeout}. Blocks the calling fiber while it runs. *)
val make : kind:kind -> string -> Bigstring.t option

(**/**)

val dimensions : string -> (int * int) option
