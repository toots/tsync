(** How a domain's vault looks in pickers (vault §8.1): a colour, chosen or
    derived from the key id, and an optional icon. Not sealed: it is shown while
    the vault is locked, and holds nothing secret. *)

type t = {
  color : string option;  (** [#rrggbb], lower case; [None]: the key id's *)
  icon : string option;  (** a square PNG, at most [icon_max_side] pixels *)
  modified : int;  (** seconds since the epoch *)
  unknown : (string * Yojson.Safe.t) list;
      (** the members this version does not know, kept through a rewrite *)
}

val none : t

(** The palette a default is drawn from, and the colour a key id gets. *)
val palette : string list

val default_color : key_id:string -> string

(** [color] when chosen, else the key id's. *)
val color : t -> key_id:string -> string

(** [Error] says what is wrong with a colour or an icon. *)
val check_color : string -> (string, string) result

val check_icon : string -> (string, string) result
val icon_max_side : int
val icon_max_bytes : int
val to_string : t -> string

(** [Error] for a body that is not an appearance, or holds a bad colour or icon.
*)
val of_string : string -> (t, string) result
