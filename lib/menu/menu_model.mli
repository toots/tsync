(** The status menu (spec frontends/menu-model.md): pure functions from what
    owners report to an icon, a tooltip and rows. Every string a status menu
    shows is produced here. *)

type action =
  | Nothing
  | Open_folder of string
  | Reveal of { domain : string; rel : string }
  | Set_paused of bool
  | Show_stats
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;  (** a generic freedesktop name *)
  checked : bool option;  (** present on a checkmark row *)
  indent : int;
  action : action;
  submenu : bool;
}

type entry = Separator | Item of item
type t = { icon : string; tooltip : string; entries : entry list }

(** {1 Formatters (§3)} *)

val duration : float -> string option
val time_left : remaining:float -> rate:float -> string
val ellipsis : string -> string
val file_icon : string -> string

(** {1 The menu (§2, §4, §5)} *)

(** What the model reads of one [status] reply. *)
type status

(** [None] when the reply's [ok] is not [true]. A field of another type than §2
    states is absent; no reply makes this fail. *)
val status_of_json : Yojson.Safe.t -> status option

(** The domains in configuration order, each with its status or [None] when
    unreachable. [quit] is the label of the quit row, absent for a client whose
    process must keep running. *)
val render : ?quit:string -> (string * status option) list -> t

(** {1 Stats submenu (§6)} *)

(** What the model reads of one process's [stats] reply. *)
type stats

(** [None] when the reply's [ok] is not [true]; total as {!status_of_json}. *)
val stats_of_json : Yojson.Safe.t -> stats option

(** The one row shown until the first answer. *)
val stats_placeholder : entry list

(** The rows for the processes that answered; never empty. *)
val stats : stats list -> entry list

(** {1 JSON form (§7)} *)

val entry_to_json : entry -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
