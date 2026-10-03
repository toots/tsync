(** The bridge a host process calls (android §5): every entry is total, text is
    UTF-8, and a call blocks only its own thread. A second set of entries takes
    the owner explicitly, for the command group. *)

open Tsync_owner

(** What the host provides before the core initialises (android §4.1): its trust
    store and its one transfer root. Marks this process as an embedding host,
    which refuses cleartext to anything but loopback. *)
val init : trust_store:string -> transfer_root:string -> unit

(** [""] when the config, or the [candidate] text in its place, loads and names
    the domain ([""]: its only one). Starts nothing and takes no lock. *)
val check_config : ?candidate:string -> string -> string

(** [""] once the domain is owned and its handler answers (android §3.1);
    idempotent, concurrent callers wait for the first. *)
val boot : ?pull_params:Pulls.params -> string -> string

val request : string -> string
val status : unit -> string

(** A handle > 0, or −errno. *)
val open_ : string -> int

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
val read_in : Owner.embedded -> int -> off:int -> Tsync_core.Bigstring.t -> int

(** The config and the domain a name selects, validated for this frontend. *)
val load :
  ?candidate:string ->
  string ->
  Tsync_config.Config.t * Tsync_config.Config.domain

(** A failure's sentence. *)
val sentence : exn -> string
