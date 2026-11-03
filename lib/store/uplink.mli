(** Upload admission and pacing per network link (spec
    algorithms/uplink-governor.md): a token bucket with an in-flight window,
    three FIFO lines (bodies that are not chunks, chunks, the slices of admitted
    chunks), and the delay-driven law setting the rate.

    The supervisor is the governor owner: it runs each link's law and splits its
    rate among the processes that lease from it. Every other process leases, and
    runs the law itself (Local) while no owner answers. A Local process never
    takes ownership: tsync is expected to run under its supervisor, so there is
    no machine-wide governor lock. *)

type t
type settings = { enabled : bool; law : Uplink_law.settings }

(** Admits everything at once and counts nothing: a store without a link. *)
val none : t

(** The admission of a named link, one per process, shared by every store on it;
    the first settings named win. *)
val link : string -> settings -> t

(** Probe a store on the link while bytes are in flight, and cut on its
    timeouts. *)
val attach :
  t ->
  store:string ->
  probe:(unit -> unit) ->
  health:Tsync_core.Health.t ->
  unit

(** Become the governor owner, restoring laws from [state_file] and saving them
    there; a link first named by a lessee takes [settings_for] its name. *)
val own : ?state_file:string -> (string -> settings) -> unit

(** Lease from the owner through [call], one renewal per tick. *)
val lease : (Uplink_lease.request -> Uplink_lease.answer option) -> unit

(** The owner's answer to a renewal; [None] refuses it. *)
val renewal : Uplink_lease.request -> Uplink_lease.answer option

type ticket

(** Suspends until the attempt may start; STOPPING once the process stops. A
    body that is not a [chunk] is billed whole and admitted before every waiting
    chunk and slice; a chunk is billed its overhead, then each slice through
    {!pace} (uplink-governor §4.1, §4.3). *)
val acquire : t -> chunk:bool -> int -> ticket

(** Admitted now or refused, never waits. *)
val try_acquire : t -> chunk:bool -> int -> ticket option

(** Suspends until the next slice of a chunk may be written, and returns its
    length, at most [remaining]; a ticket that is not a chunk's, or a disabled
    link's, gets [remaining] at once. STOPPING once the process stops. *)
val pace : t -> ticket -> remaining:int -> int

val completed : t -> ticket -> unit
val abandoned : t -> ticket -> unit

(** Bodies waiting in line. *)
val waiting : t -> int

(** One attempt carrying [bytes] upstream, admitted per [mode] and reported
    exactly once; a best-effort attempt refused admission is cancelled without
    running. The attempt is handed its {!pace}, which the writer calls before
    every slice of the body. *)
val admitted :
  t -> Store.mode -> chunk:bool -> int -> ((int -> int) -> 'a) -> 'a

type link_state = [ `Ramping | `Steady | `Backing_off | `Leased ]
type limit = Uplink_law.limit = Configured | Measured | Estimating
type process_mode = [ `Owner | `Leased | `Local ]

type lessee_status = {
  pid : int;
  rate : float;
  in_flight : int;
  waiting : int;
  held_back : bool;
  probe_ms : float option;
}
[@@deriving yojson]

(** §4.9: [rate] is the law's in an Owner or Local process, the grant in a
    Leased one. *)
type link_status = {
  name : string;
  state : link_state;
  limit : limit;
  max_rate : float option;
  rate : float;
  capacity : float option;
  achieved : float;
  base_delay_ms : float option;
  queueing_delay_ms : float;
  in_flight : int;
  window : float;
  drops : int;
  headroom : float;
  target_delay_ms : float;
  waiting : int;
  mode : process_mode;
  own_rate : float option;  (** an owner's own grant *)
  lessees : lessee_status list;
}
[@@deriving yojson]

(** Links in use, by name. *)
val status : unit -> link_status list

module Budget : sig
  type t

  val create : rate:float -> now:float -> t
  val fits : t -> int -> bool
  val admits : t -> now:float -> chunk:bool -> int -> bool
  val take : t -> now:float -> chunk:bool -> int -> unit
  val spends : t -> now:float -> int -> bool
  val spend : t -> now:float -> int -> unit

  (** The next slice of a chunk with [remaining] bytes left to write. *)
  val slice : t -> remaining:int -> int

  val release : t -> int -> unit
  val wait_for : t -> now:float -> int -> float
  val set_rate : t -> now:float -> float -> unit
end
