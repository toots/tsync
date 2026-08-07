(** One configuration setting, described rather than coded.

    A backend or frontend declares what it needs alongside its factory, and
    [tsync configure] prompts for it without knowing what a bucket or a listen
    port is. Declarative on purpose: adding a setting is a line in a driver, not
    an edit to the configure UI.

    One type for both, because a setting is a setting. It was two — mirrored
    records with mirrored prompt code — and they had already drifted: only one
    side had {!Int}, and blank strings were kept on one side and dropped on the
    other. *)

type typ = [ `String | `Bool | `Int ]

type t = {
  name : string;  (** The JSON key this is stored under. *)
  label : string;  (** What the prompt calls it. *)
  typ : typ;
  default : string option;
      (** [None] is required. [Some ""] is optional and omitted from the config
          when left blank. [Some s] is optional with default [s]. Always the
          textual form, whatever {!typ} says: this is what a prompt shows. *)
  secret : bool;
      (** Read without echo, and masked wherever the config is printed. *)
}
