(** The fetch of [https://<host><path>], a site's [/.well-known/] document: the
    body of a 200 of at most 256 KiB within 5 s, without redirects, asked with a
    User-Agent, else [None]. A test replaces it. *)
val fetch : (string -> string -> string option) Atomic.t
