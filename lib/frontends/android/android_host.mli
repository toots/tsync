(** The bridge a host process calls (android §5): every entry is total, text is
    UTF-8, and a call blocks only its own thread. A second set of entries takes
    the owner explicitly, for the command group. *)

open Tsync_owner

(** A host's resource bounds (android §4.1 item 7); [None] keeps the default.
    [release_growth] is in bytes. *)
type bounds = {
  workers : int option;
  may_block : int option;
  release_growth : int option;
}

(** What the host provides before the core initialises (android §4.1): its
    bounds, trust store and one transfer root. Marks this process as an
    embedding host, which refuses cleartext to anything but loopback. Raises
    [Invalid_argument] when bounds come after the scheduler started. *)
val init :
  ?bounds:bounds -> trust_store:string -> transfer_root:string -> unit -> unit

(** [""] when the config, or the [candidate] text in its place, loads and names
    the domain ([""]: its only one). Starts nothing and takes no lock. *)
val check_config : ?candidate:string -> string -> string

(** [""] once the domain is owned and its handler answers (android §3.1);
    idempotent per domain, concurrent callers wait for the first. A domain
    booted stays booted for the life of the process. *)
val boot : ?pull_params:Pulls.params -> string -> string

(** [request], [status] and [open_] name a booted domain, and refuse one that is
    not as every entry does. *)
val request : string -> string -> string

(** setup-link §6.3: fetches and opens a setup link, before any config exists;
    JSON
    [{"from","domains":[{"name","url","secret"}],"skipped":[{"name",
     "reason"}],"about"}], or [{"error"}] with the sentence to show. *)
val setup_link : string -> string

val status : string -> string

(** A handle > 0, or −errno; unique across domains, so the calls on a handle
    take none. *)
val open_ : string -> string -> int

val size : int -> int

(** Bytes written at the start of the buffer, or −errno. *)
val read : int -> off:int -> Tsync_core.Bigstring.t -> int

val close : int -> int

(** Blocks the calling thread until the core has a notice (android §4.2). *)
val next_notice : unit -> string

(** {2 Over an owner the caller holds, from a fiber} *)

val frontend : unit -> Tsync_status.Status_report.frontend option
val request_in : Owner.embedded -> string -> string
val status_in : Owner.embedded -> string
val open_in : Owner.embedded -> string -> int
val read_in : int -> off:int -> Tsync_core.Bigstring.t -> int

(** The config and the domain a name selects, validated for this frontend. *)
val load :
  ?candidate:string ->
  string ->
  Tsync_config.Config.t * Tsync_config.Config.domain

(** A failure's sentence. *)
val sentence : exn -> string
