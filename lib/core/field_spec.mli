(** Field specifications (spec 05 §2.1, 06 §5): each driver and frontend
    declares its own fields; the config parser refuses keys a spec does not
    list, the wizard prompts from them, and reports mask every field not
    declared non-secret. *)

type kind = String | Bool | Int | Size | Path | List | Float

type field = {
  name : string;
  label : string;
  kind : kind;
  default : string option;
  secret : bool;
  required : bool;
  check : string -> string option;  (** a rule on the value's text, or [None] *)
}

val f :
  ?secret:bool ->
  ?required:bool ->
  ?default:string ->
  ?check:(string -> string option) ->
  string ->
  string ->
  kind ->
  field

(** A parsed field value. *)
type value =
  | S of string
  | B of bool
  | I of int
  | F of float
  | L of string list

val is_loopback : string -> bool

(** Refuses plain http to a host that is not a loopback address; a bare host is
    accepted when [bare_host]. *)
val http_url : ?bare_host:bool -> string -> string option

val min_secret_length : int
val secret_length : string -> string option
val absolute_path : string -> string option
val absolute_or_home : string -> string option
