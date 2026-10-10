(** The share page's assets, compiled from [lambda/] so the listener and the
    cloud share function serve the same bytes. *)

val browse : string
val player : string

(** The generic preview image, a PNG (http-proxy §A9.8). *)
val card_base64 : string
