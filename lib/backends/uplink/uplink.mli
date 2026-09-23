(** Admission to a link: the gate a store's writes go through.

    A store asks before each body it sends and says how it went after. What it
    asks is a record of closures rather than a module, so a store built once can
    be handed whichever gate its config names, and a gate answering for one
    store can later be swapped for one answering to a daemon without the store
    changing. Upload only: a read is the caller waiting, and is not made to wait
    longer here.

    Two gates. {!Make.capped} is a ceiling on one store, a budget of its own.
    The process governor, {!Make.process}, is one {!Uplink_control} for every
    store in the process, stepped by a ticker and fed by probes: the one link
    the process has, written at the rate the law chooses. *)

type 'io admission = {
  acquire : bytes:int -> 'io;  (** Returns once [bytes] may be sent. *)
  completed : bytes:int -> elapsed:float -> unit;
      (** [bytes] were answered, [elapsed] seconds after [acquire] returned. *)
  abandoned : bytes:int -> unit;
      (** [bytes] were given up on, however that happened: they have left the
          link. *)
  now : unit -> float;
      (** The clock [elapsed] is read off, so a store need not hold one. *)
  waiting : unit -> int;  (** Bodies queued behind the gate right now. *)
  try_admit : bytes:int -> bool;
      (** Room for [bytes] now, with nothing ahead: the drop path's question.
          Pure, and good only until this turn yields; the [acquire] that follows
          takes the room with no bind between. *)
}

(** A body of at most this many bytes may pass ahead of what is queued, when the
    budget covers it: a cursor or a journal entry should not sit behind a chunk.
    Bounded, so a run of them cannot keep a chunk waiting for long. *)
val small_body : int ref

(** How long a probe is given before it is read as the length of the timeout
    itself: an enormous delay, which the next step cuts hard on. *)
val probe_timeout : float ref

(** Where the governor says what it decided. Handed in rather than named, so
    this library names no logger: [rate] spells bytes per second the way the
    embedding program does. *)
module type LOG = sig
  val info : string -> unit
  val warn : string -> unit
  val rate : float -> string
end

(** Says nothing; for a test, or an embedding with nowhere to say it. *)
module Silent : LOG

(** The name a store is on when its config names none. *)
val default_link : string

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Log : LOG) : sig
  (** Admits everything at once: a store with no ceiling. *)
  val unbounded : unit Io.t admission

  (** A ceiling of [rate] bytes per second on one store, over its own
      {!Uplink_budget}. Waiters are served in order, each woken the moment the
      budget next allows it, whether by refill or by a body leaving the link; a
      body larger than the bucket goes alone and is paid off before the next, as
      the budget says. *)
  val capped : rate:float -> unit Io.t admission

  (** [compose first second] asks [first] and then [second], and tells both: a
      store's own ceiling in front of the process governor. *)
  val compose :
    unit Io.t admission -> unit Io.t admission -> unit Io.t admission

  (** {1 The process governor: one link at a time, all of them together} *)

  (** Who is asking. [Background] takes from the budget; [Foreground] is a user
      waiting, and passes. Upload only today, so every store is [Background];
      the class is here so a download path can say otherwise without the
      interface changing. *)
  type class_ = Background | Foreground

  (** What a process is to its links. The [Owner] serves the daemon's socket: it
      runs each link's law, splits its rate among those holding a share of that
      link, and answers their renewals; its own writes hold a share like any
      other. A [Leased] process asks the owner for its shares every interval and
      runs no law of its own. A [Local] one runs the laws alone: no daemon
      answered, or the one that did does not know the question. A process is one
      of these for every link it has at once. *)
  type mode = Owner | Leased | Local

  val string_of_mode : mode -> string

  (** One link's governor: its law, its budget, the line behind it, and, for an
      owner, the lessees holding shares of it. *)
  type t

  (** The process's links, and what the process is to them. *)
  type process

  val create_process :
    ?defaults:Uplink_control.settings ->
    ?overrides:(string * Uplink_control.settings) list ->
    unit ->
    process

  (** A lone {!default_link} in a fresh local process: what a test builds. *)
  val create : ?settings:Uplink_control.settings -> unit -> t

  (** Applied once per process, before the first store is built. A later call is
      a no-op: a process opening a second domain has the same links. *)
  val configure :
    defaults:Uplink_control.settings ->
    overrides:(string * Uplink_control.settings) list ->
    unit

  (** The one process every store here belongs to. Made on the defaults if
      nothing configured it. *)
  val process : unit -> process

  (** The link of that name, made on first mention: its override if the process
      has one for the name, else the defaults. *)
  val link : process -> string -> t

  (** Every link something uses, by name, sorted. A link nothing writes to,
      probes or leases is kept but not listed. *)
  val links : process -> (string * t) list

  (** Every link, the unused ones too. *)
  val all_links : process -> (string * t) list

  val process_of : t -> process
  val name : t -> string
  val enabled : t -> bool
  val control : t -> Uplink_control.t
  val mode : process -> mode

  (** This process serves the links' owner socket. Said before its engines
      start, so a lessee never finds the socket up and the owner not yet
      answering, and it stays said. Starts the ticker: the split is wanted
      whether or not the owner itself has anything to send. *)
  val own : process -> unit

  (** This process asks the owner over [send] for its shares, one line each way,
      renewing every interval the owner names. Refused, which an older daemon
      does, or unanswered three times, it runs the laws alone and asks again now
      and then. A process that has said {!own} ignores this. *)
  val lease_through : process -> send:(string -> string Io.t) -> unit

  (** A lessee's renewal, answered by the owner: a grant in bytes per second for
      each link reported, and the interval to renew at. A link the owner has no
      store on is made for the lessee, on the owner's settings for the name.
      [None] from a process that is not the owner, which the caller turns into a
      refusal. *)
  (** A lessee's share of one link, and what holds the owner's rate there. *)
  type grant = { rate : float; limit : Uplink_control.limit option }

  (** Every body waiting on any of the process's links fails with [exn],
      having taken nothing: for a process stopping, whose writes are owed on
      disk and not worth a wait for the link. *)
  val cancel_waiting : process -> exn -> unit

  val lease_renewal :
    process ->
    pid:int ->
    (string * Uplink_lease.report) list ->
    ((string * grant) list * float) option

  (** The owner's answer on the wire: [flat] for a lessee that asked in the
      one-link shape, which reads its grant at the top. *)
  val answer_json :
    flat:bool -> interval:float -> (string * grant) list -> Yojson.Safe.t

  (** Waits for room on the link, in order; a body of at most {!small_body}
      bytes passes ahead when the budget covers it, and no more than the head's
      own size passes it in all. Returns at once when the
      link is disabled or the asker is [Foreground]. Starts the process's ticker
      on first use. *)
  val acquire : t -> class_:class_ -> bytes:int -> unit Io.t

  (** The drop path's question: room now, or not at all; a [false] is a drop and
      charges nothing. A [true] holds only until this turn yields: the caller's
      {!acquire} that follows takes the room synchronously, with no bind
      between, which is what a chunk forward relies on. Always [true] when the
      link is disabled. What {!admission} answers as its [try_admit]. *)
  val try_admit : t -> bytes:int -> bool

  (** What a store hands its constructor: this link, asked as [class_]. *)
  val admission : t -> class_ -> unit Io.t admission

  (** A store on the link with governed bytes crossing it: whether to leave it
      alone just now ([held], a store its own retry loop has taken out), how
      many of its requests have timed out so far ([timeouts], read each step and
      the growth since cut on), and one small round trip to time ([probe]).
      Probed every tick while the link has bytes in flight and the store is not
      held; never when idle, since a probe is a billed request. *)
  val attach :
    t ->
    name:string ->
    held:(unit -> bool) ->
    timeouts:(unit -> int) ->
    probe:(unit -> unit Io.t) ->
    unit

  val waiting : t -> int

  (** One link, under the names every report uses. *)
  val json : t -> (string * Yojson.Safe.t) list

  (** Every link something uses, each as {!json} shows it, by name. *)
  val json_links : process -> (string * Yojson.Safe.t) list
end
