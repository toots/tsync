(** The shared mime table ([lambda/mime.json]), the one the share servers and
    the cloud share function answer content types from. *)

(** Lowercase extension to mime type. *)
val table : (string * string) list

(** By the name's lowercase extension. *)
val of_name : string -> string option

(** The type a file's bytes are served as (http-proxy §A9.5): by name, unless
    the table's [@signatures] has an entry for its extension whose every offset
    inside the file holds its byte. [head n] reads the first [n] bytes, and is
    called only for such an extension. *)
val served : size:int -> head:(int -> string) -> string -> string option
