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

(** {1 The stats submenu}

    [tsync stats] with most of it left out: the figures someone opens a tray
    menu to see, rather than the ones they would run the command for. Fetched
    when the submenu opens, not on the poll -- reaching a backend is a round
    trip, and the poll happens whether anyone is looking or not. *)

type backend_stats = {
  backend_name : string;
  role : string;
  backend_reachable : bool;
  latency_ms : float option;
  backend_error : string option;
  journal_entries : int option;
  journal_behind : int option;
}

(** [None] throughout means the daemon did not report that figure, which is
    distinct from reporting zero: a frontend that keeps no byte counters should
    not be drawn as one that read nothing. *)
type domain_stats = {
  domain_name : string;
  mount_point : string option;
  read_only : bool;
  versioning : bool;
  cache_chunks : int option;
  cache_bytes : int64 option;
  cache_max : int64 option;
  in_uploads : int option;
  in_downloads : int option;
  staged : int option;
  bytes_read : int64 option;
  bytes_written : int64 option;
  wal_pending : int option;
  wal_stuck : int option;
  backends : backend_stats list;
}

(** One answering daemon. Linux gives each domain its own process, so there is
    usually one of these per domain. *)
type stats = {
  host : string;
  frontend : string;
  pid : int;
  uptime : float;
  cpu_percent : float;  (** already a percentage: 0.98 means 0.98% *)
  rss : int64;
  heap : int64;
  uploaded : int64;
  up_rate : float;
  downloaded : int64;
  down_rate : float;
  domain_stats : domain_stats list;
}

type action =
  | Nothing
  | Open_folder of string
  | Reveal_file of string
  | Set_paused of bool
  | Show_stats
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
  submenu : bool;
      (** Opens a menu of its own rather than doing something. Only the marker
          lives here: what is in it is fetched when it opens, so the rows belong
          to whoever fetched them. Distinct from [indent], which shifts a row
          inside the menu it is already in. *)
}

type entry = Separator | Item of item
type menu = { icon : string; tooltip : string; entries : entry list }

val render : status list -> menu

(** The stats submenu's rows, to be installed under the row whose action is
    [Show_stats]. Never empty: a submenu with nothing in it is one some panels
    decline to open. *)
val stats_entries : stats list -> entry list

(** What that submenu holds until the first answer arrives. *)
val stats_placeholder : entry list

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
