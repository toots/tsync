(** The media helper: a separate executable, [tsync-media], that links the
    FFmpeg libraries so that tsync itself does not, and that is run once per
    image it makes (spec frontends/http-proxy.md §A9.8, extensions/vault.md
    §8.1). Packages ship it apart; without it nothing makes an image.

    A request is written to the helper's standard input, so that a share's token
    never shows in a process listing: the seconds it has, then the request's own
    lines. It writes the image to its standard output and exits 0, or explains
    on its standard error and exits non-zero. *)

(** Where the helper is: [TSYNC_MEDIA_HELPER] when set, else beside the running
    executable, else in [libexec/tsync] next to its directory. *)
val path : unit -> string option

(** Whether a helper is installed. *)
val available : unit -> bool

(** The helper's output for [request], when it exits 0 by the deadline (a
    {!Rt.now} instant) with at most [max_output] bytes; [None] otherwise, the
    helper being killed past the deadline. Raises [Invalid_argument] when a line
    of [request] holds a newline. Blocks the calling fiber. *)
val run : ?max_output:int -> deadline:float -> string list -> string option

(** What the helper reads: its deadline and the request's lines, in the order
    {!run} wrote them. [None] when the input is not a request. *)
val read_request : string -> (float * string list) option
