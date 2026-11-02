(** The page and the payload a listener serves for a setup link (spec
    algorithms/setup-link.md §7); the store server finds the manifest. *)

(** [None]: no route holds a setup link at that token. *)
val answer :
  json:bool ->
  Tsync_setup_link.Setup_link.stored option ->
  Tsync_http.Server.response
