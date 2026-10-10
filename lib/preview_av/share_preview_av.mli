(** The share preview thumbnailer on the FFmpeg bindings (spec
    frontends/http-proxy.md §A9.8). Linking it fills
    {!Tsync_core.Share_preview.thumbnailer}; nothing calls it directly. *)

(**/**)

val fit : int -> int -> int * int
