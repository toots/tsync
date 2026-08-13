(** What the tray says, decided from what the daemons answered.

    A copy of macos/TsyncApp/StatusMenu.swift, deliberately: the two menus
    should read the same on both platforms, so the strings here are that file's
    strings and the test pins them. Nothing in this module knows about D-Bus,
    which is what makes that test possible on a machine with no tray. *)

type upload = {
  name : string;  (** the base name, which is what a row is labelled with *)
  rel : string;  (** where it sits under the domain root, for revealing it *)
}

(** One domain's last answer. [None] counts mean it did not answer at all --
    distinct from answering zero, which is an idle domain. *)
type status = {
  name : string;
  uploads : int option;
  downloads : int option;
  paused : bool option;
  uploading : upload list;
  pending_bytes : int64 option;
  bytes_uploaded : int64 option;  (** process-wide, so repeated per domain *)
  upload_rate : float option;  (** process-wide *)
  mount : string option;
}

val unreachable : string -> status

type action =
  | Nothing
  | Open_folder of string
  | Reveal_file of string
  | Set_paused of bool
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;
  checked : bool option;  (** [Some] draws a checkmark item at that state *)
  indent : int;
      (** Nesting the macOS menu draws, which dbusmenu has no property for. Kept
          here so the structure is the model's and how to express it is the
          renderer's. *)
  action : action;
}

type entry = Separator | Item of item
type menu = { icon : string; tooltip : string; entries : entry list }

val render : status list -> menu

(** {1 The pieces, exposed for the test that pins them} *)

val summary : status list -> string
val detail : status -> string
val traffic_line : status list -> string option
val rate_line : status list -> string option
val icon_name : status list -> string
val file_icon : string -> string

(** Decimal, like the Finder: 223200000 is ["223.2 MB"], not ["212.9 MiB"].
    Deliberately not [Metrics.human_bytes], which is 1024-based because
    [Conf_parsing.parse_size] has to read back what it prints. *)
val human_bytes : int64 -> string

(** The two largest non-zero units of a duration, abbreviated, truncated:
    [8000.] is [Some "2h 13m"]. [None] under a minute, where there is nothing
    honest to say. *)
val eta : float -> string option
