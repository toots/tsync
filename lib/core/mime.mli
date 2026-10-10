(** The shared mime table ([lambda/mime.json]), the one the share servers and
    the cloud share function answer content types from. *)

(** Lowercase extension to mime type. *)
val table : (string * string) list

(** By the name's lowercase extension. *)
val of_name : string -> string option
