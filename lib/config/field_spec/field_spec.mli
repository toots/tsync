(** One configuration setting, described rather than coded.

    A backend or frontend declares what it needs alongside its factory, so
    adding a setting is a line in a driver rather than an edit to the
    [tsync configure] UI, which knows nothing of buckets or listen ports. *)

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
