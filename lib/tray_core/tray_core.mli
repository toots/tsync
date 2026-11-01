(** A tray's work apart from drawing it (linux-tray.md §5–§6, cloud-files.md
    §15): the platform creates it with what it draws and runs {!poll} in a
    fiber; the menu's openings call {!opened} and its clicks {!run_action}, and
    the process ends when {!finished} resolves. The platform's functions are
    called from fibers, never while a lock of this module is held. *)

open Tsync_menu

type platform = {
  menu : Menu_model.t -> unit;  (** the icon, tooltip and rows of a refresh *)
  children : Menu_model.action -> Menu_model.entry list -> unit;
      (** the rows of the submenu row with that action: stats or codes *)
  marks : (string * string) list -> unit;
      (** the vault marks of the code domains, by domain (vault §8.1) *)
  notify : string -> string -> unit;  (** a summary and a body *)
  copy : string -> (unit, string) result;
      (** a one-time code onto the clipboard, never logged nor kept *)
  show : folder:bool -> string -> unit;
      (** a folder opened, or a file's folder with the file selected *)
  ask_secret : title:string -> string -> string option;
      (** a hidden entry; [None] when the user cancels *)
  can_ask : unit -> (unit, string) result;
  code_domains : string list -> string list;
      (** of the domains listing totp, those whose codes it can copy *)
  configured_folder : Tsync_config.Config.domain -> string option;
      (** where the domain is shown when its owner has not said *)
}

type t

(** [quit] labels the quit row. *)
val create : quit:string -> platform -> t

(** Refreshes now, then every [poll_interval], for as long as the process. *)
val poll : t -> unit

(** At an opening of the menu: the stats and codes rows, debounced. *)
val opened : t -> unit

val run_action : t -> Menu_model.action -> unit

(** Resolved with the exit status when the menu's Quit is chosen. *)
val finished : t -> int Tsync_core.Rt.Promise.t
