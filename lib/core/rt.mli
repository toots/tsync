(** The runtime every concurrent part of tsync is written against (spec 01 §6):
    direct-style fibers on the vendored duppy scheduler.

    Fibers run on a pool of domains and may resume on any of them, so shared
    state is guarded by a lock or an atomic, never by confinement. A system call
    inside a fiber blocks only that fiber. *)

(** The cancellation a fiber receives at its current wait. *)
exception Cancelled

(** Raised by {!with_timeout}, {!with_stall_timeout} and bounded waits. *)
exception Timeout

val is_cancelled : exn -> bool

(** Monotonic seconds with an arbitrary origin. *)
val now : unit -> float

(** Raises the pending cancellation of the calling fiber, if any. *)
val check : unit -> unit

(** How a fiber is scheduled, spec 01 §6.5: [`Threaded] is may-block work and
    the default, [`Immediate] is non-blocking I/O, [`Direct] is time-sensitive
    work. The last two run on a worker of the pool itself and stall it for as
    long as they run. *)
type execution = [ `Immediate | `Direct | `Threaded ]

(** Run a detached fiber. It never fails: an escaping exception other than a
    cancellation is logged. *)
val spawn : ?name:string -> ?execution:execution -> (unit -> unit) -> unit

(** [within execution fn] runs [fn] with the calling fiber scheduled as
    [execution], then puts it back. Waits inside [fn] resume as [execution], and
    children started inside it ({!async}, {!all}, {!first}) start as it. Free
    when the fiber is already scheduled so.

    Entering and leaving are suspension points that may resume on another system
    thread, so never inside [Mutex.protect]. Entering [`Threaded] waits for a
    slot, and that wait is not cancellable. *)
val within : execution -> (unit -> 'a) -> 'a

(** Block the calling system thread until [fn], run as a fiber, returns or
    raises. This is how the main thread and foreign threads (FUSE, JNI) enter
    the runtime. *)
val run_sync : (unit -> 'a) -> 'a

(** Park until the resolver handed to [register] is called. The resolver may be
    called from any thread; it answers [false] when the fiber was already woken,
    by a cancellation for example. [register] answers how to withdraw the
    resolver, run (perhaps twice) when a cancellation woke the fiber. *)
val suspend : ((('a, exn) result -> bool) -> unit -> unit) -> 'a

(** The calling fiber's identity; code outside any fiber shares one. *)
type fiber

val self : unit -> fiber
val same : fiber -> fiber -> bool

(** Cancellable sleep. *)
val sleep : float -> unit

val yield : unit -> unit

(** Wait until a descriptor is ready, or raise {!Timeout} after [timeout]. *)
val wait_readable : ?timeout:float -> Unix.file_descr -> unit

val wait_writable : ?timeout:float -> Unix.file_descr -> unit

(** Call [fire] once, [delay] seconds from now, outside any fiber. *)
val timer : ?execution:execution -> float -> (unit -> unit) -> unit

(** One-shot promises. Resolving never runs a waiter inside the resolver. *)
module Promise : sig
  type 'a t

  val create : unit -> 'a t
  val resolved : 'a -> 'a t

  (** Raises [Invalid_argument] when already resolved. *)
  val resolve : 'a t -> 'a -> unit

  val try_resolve : 'a t -> 'a -> bool
  val try_resolve_result : 'a t -> ('a, exn) result -> bool
  val fail : 'a t -> exn -> unit
  val await : 'a t -> 'a
  val peek : 'a t -> ('a, exn) result option
  val is_resolved : 'a t -> bool
end

(** Run [fn] in a child fiber of the caller, scheduled as the caller is;
    cancelling the caller cancels it. *)
val async : (unit -> 'a) -> 'a Promise.t

(** Run concurrently and wait for all; results keep input order and the first
    failure is re-raised once every child has finished. *)
val all : (unit -> 'a) list -> 'a list

val both : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
val map_concurrently : ('a -> 'b) -> 'a list -> 'b list
val iter_concurrently : ('a -> unit) -> 'a list -> unit

(** At most [width] items in flight, pulled by workers; results in input order.
*)
val map_bounded : width:int -> ('a -> 'b) -> 'a list -> 'b list

val iter_bounded : width:int -> ('a -> unit) -> 'a list -> unit

(** [width] workers pull from [next] until it answers [None]. *)
val each : width:int -> (unit -> 'a option) -> ('a -> unit) -> unit

(** The first to finish, successfully or not, wins; the others are cancelled
    and, unless [detach], waited for, so none outlives the call. Detach only
    around work cancellation cannot interrupt, such as a blocking system call.
*)
val first : ?detach:bool -> (unit -> 'a) list -> 'a

val with_timeout : ?detach:bool -> float -> (unit -> 'a) -> 'a

(** [with_stall_timeout window fn] passes [fn] a progress signal and fails with
    {!Timeout} once [window] passes without it. *)
val with_stall_timeout : float -> ((unit -> unit) -> 'a) -> 'a

(** FIFO fiber mutex, released however its holder ends. *)
module Fmutex : sig
  type t

  val create : unit -> t
  val lock : t -> unit
  val unlock : t -> unit
  val with_lock : t -> (unit -> 'a) -> 'a
  val is_locked : t -> bool
end

(** A condition carrying no value: a woken waiter re-reads its state. *)
module Condition : sig
  type t

  val create : unit -> t
  val wait : t -> Fmutex.t -> unit
  val signal : t -> unit
  val broadcast : t -> unit
end

(** A broadcast with no mutex and no value. A waiter reads {!Signal.version}
    before checking its state and passes it as [since], so a broadcast between
    the check and the wait is not lost. *)
module Signal : sig
  type t

  val create : unit -> t
  val version : t -> int
  val wait : ?since:int -> t -> unit
  val broadcast : t -> unit
end

(** Counting semaphore with FIFO hand-off. *)
module Semaphore : sig
  type t

  val create : ?name:string -> int -> t
  val acquire : t -> unit
  val try_acquire : t -> bool
  val release : t -> unit
  val with_slot : t -> (unit -> 'a) -> 'a

  (** Name, slots held, waiters, width. *)
  val stats : t -> string * int * int * int
end

(**/**)

val detached_failure : (string -> exn -> unit) ref
val task_error : (exn -> Printexc.raw_backtrace -> unit) ref
