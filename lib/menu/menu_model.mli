(** The status menu (spec frontends/menu-model.md): pure functions from what
    owners report to an icon, a tooltip and rows. Every string a status menu
    shows is produced here. *)

type action =
  | Nothing
  | Open_folder of string
  | Reveal of { domain : string; rel : string }
  | Set_paused of bool
  | Show_stats
  | Show_codes
  | Copy_code of { domain : string; id : string }
  | Unlock of string
  | Add_code of string
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;  (** a generic freedesktop name *)
  checked : bool option;  (** present on a checkmark row *)
  indent : int;
  action : action;
  submenu : bool;
  vault : string option;
      (** the domain whose vault a header row names, which a client marks with
          the vault's appearance (vault §8.1) *)
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
    process must keep running. [codes] are the code domains (§5): with none
    there is no One-time codes row. *)
val render :
  ?quit:string -> ?codes:string list -> (string * status option) list -> t

(** {1 Stats submenu (§6)} *)

(** What the model reads of one process's [stats] reply. *)
type stats

(** [None] when the reply's [ok] is not [true]; total as {!status_of_json}. *)
val stats_of_json : Yojson.Safe.t -> stats option

(** The one row shown until the first answer. *)
val stats_placeholder : entry list

(** The rows for the processes that answered; never empty. *)
val stats : stats list -> entry list

(** {1 Codes submenu (§7)} *)

(** What the model reads of one domain's [totp_list] answer. *)
type codes

(** The reply, or [None] when the owner did not answer; total. *)
val codes_of_json : Yojson.Safe.t option -> codes

val codes_placeholder : entry list

(** The code domains in configuration order with their answers; never empty, and
    no row carries a code. [add] (default [true]) ends each answering domain
    with its Add a code row. *)
val codes : ?add:bool -> (string * codes) list -> entry list

(** {1 JSON form (§8)} *)

val entry_to_json : entry -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
