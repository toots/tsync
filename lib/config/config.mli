(** The config (spec 05 §2): one JSON object, validated strictly. Unknown keys
    are refused at every level, every value has a declared type, and every error
    names the JSON path of the value. *)

open Tsync_core

exception Invalid of string

type value = Field_spec.value =
  | S of string
  | B of bool
  | I of int
  | F of float
  | L of string list

type backend = {
  btype : string;
  bname : string;
  role : Tsync_store.Composite.role;
  link : string option;  (** [None] for a local store *)
  fields : (string * value) list;  (** the driver's fields *)
}

type frontend = { ftype : string; options : (string * value) list }

(** The extensions of this release (05 §2.1). *)
val extension_names : string list

type domain = {
  name : Domain_name.t;
  backends : backend list;  (** in read order: role, then config order *)
  frontends : frontend list;
  extensions : string list option;
      (** the extensions this client uses; [None] follows the main's stated list
          (05 §2.1 rule 5) *)
  symlinks : [ `Keep | `Follow | `Skip ] option;
  versioning : bool;
  read_only : bool;  (** forced when no backend has a writable role *)
  chunk_size : int option;
  cache_chunk_size : int option;
  max_cache : int option;
  batch_delay : float option;
  project_width : int option;
  max_entry_commands : int option;
  project_lease : float option;
  project_quarantine : float option;
  project_settle : float option;
}

val default_symlinks : [ `Keep | `Follow | `Skip ]

(** The advanced settings a domain configures, else the application's defaults
    (05 §2.1). *)
val tuning : domain -> Tuning.t

(** The domain-wide settings in force for a domain, as its http-proxy listener
    states them. *)
val stated : domain -> Tsync_store.Store.domain_settings

(** Where each domain-wide setting in force comes from: "config", "main" or
    "default". *)
val sources :
  domain -> Tsync_store.Store.domain_settings option -> (string * string) list

(** The extensions a domain uses here (05 §2.1 rule 5): the list its main
    states, narrowed by a configured one; behind a main that states nothing, the
    configured list. Unknown names are dropped. *)
val extensions_in_force :
  domain -> Tsync_store.Store.domain_settings option -> string list

(** The advanced settings and the symlink policy in force given what the main
    states: the main's values where it states them. INVALID naming both values
    when a configured one differs, or exceeds the main's entry size. *)
val in_force :
  domain ->
  Tsync_store.Store.domain_settings option ->
  Tuning.t * [ `Keep | `Follow | `Skip ]

(** One link's uplink settings (06 §7). *)
type link = {
  enabled : bool;
  headroom : float;
  target_delay_ms : float;
  min_rate : int;
  max_rate : int option;
}

type t = {
  client_name : string;
  tls : string option;
  max_uploads : int;
  max_chunk_buffers : int;
  max_downloads : int;
  uplink : link;
  links : (string * link) list;  (** overrides merged over [uplink] *)
  domains : domain list;
}

(** Raises {!Invalid}, also for a backend or frontend type no linked library
    registered ({!Tsync_store.Driver}, {!Frontend}). *)
val of_string : string -> t

val of_json : Yojson.Safe.t -> t

(** The client name when the config gives none. *)
val hostname : unit -> string

(** [512K], [8M], [1.5 GiB], [1048576]. *)
val parse_size : string -> int option

val bool_of_string_opt : string -> bool option
val link_settings : t -> string -> link
val uplink_settings : link -> Tsync_store.Uplink.settings
val frontend : domain -> string -> frontend option
val find_domain : t -> string -> domain option

(** An explicit name, else the default domain if configured, else the only one.
*)
val resolve : ?name:string -> ?default:string -> t -> domain

val str : backend -> string -> string option
val flag : ?default:bool -> (string * value) list -> string -> bool
val num : (string * value) list -> string -> int option
val fstr : (string * value) list -> string -> string option
val ffloat : (string * value) list -> string -> float option

type shown = Secret | Shown of value

(** Fields for a report: secrets and fields without a spec are masked. *)
val masked_fields :
  specs:Field_spec.field list -> (string * value) list -> (string * shown) list

val value_to_string : value -> string
