(** One configuration setting, described rather than coded.

    A backend or frontend declares what it needs alongside its factory, so
    adding a setting is a line in a driver rather than an edit to the
    [tsync config --edit] UI, which knows nothing of buckets or listen ports. *)

type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;  (** The JSON key this is stored under. *)
  label : string;  (** What the prompt calls it. *)
  typ : typ;
  default : string option;
      (** [None] is required, [Some ""] is optional and omitted from the config
          when left blank, [Some s] is optional with default [s]. Always the
          textual form, whatever {!typ} says. *)
  secret : bool;
      (** Read without echo, and masked wherever the config is printed. *)
}

(** Read a [`Bool] field's value, as a driver or frontend receives it: a string,
    since [tsync config --edit] writes a JSON boolean that {!Conf_parsing}
    flattens and a hand-edited config holds whatever was typed.

    [default] is what an absent or unrecognised value means, and is why this is
    shared rather than spelled at each reader. *)
val bool : default:bool -> string option -> bool

(** What a report or a prompt shows in place of a secret that is set. *)
val masked : string

(** [v] as it may be shown: {!masked} for a secret field that is set. *)
val mask : t -> string -> string

(** {!mask} for the field named [name] in [spec]; a name the spec does not know
    is shown as it is. *)
val mask_named : t list -> string -> string -> string
