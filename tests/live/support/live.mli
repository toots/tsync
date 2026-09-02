(** Scaffolding for suites run by hand against a real domain.

    A live suite is a list of commands and what each should say, so adding one
    is adding a record rather than writing a runner. TSYNC_LIVE_CONFIG names the
    config JSON and TSYNC_BIN the binary under test; without the first, a suite
    exits 2 rather than reporting a pass it did not earn. {!domain} and {!mount}
    are read from that config, so a suite holds no second copy of them to
    disagree with. *)

val domain : string
val mount : string

(** A scratch directory of this run's own, removed when nothing failed. *)
val scratch : string

val home : string

(** A path naming the domain side, under a prefix unique to this run. *)
val in_domain : string -> string

(** The same, domain-relative, for a command taking a key rather than a path. *)
val rel_in_domain : string -> string

(** A path under {!scratch}. *)
val local : string -> string

(** [Filename.quote]. *)
val q : string -> string

type expect =
  | Copied of int  (** the summary's copied count *)
  | Skipped of int
  | Dirs of int
  | Failed of int
  | Says of string  (** the output contains this *)
  | Silent_on of string
  | Moved_nothing  (** no bytes crossed the wire *)
  | Holds of string * (unit -> bool)
      (** anything the output cannot answer, named by its first half: a file on
          disk, a permission, a link that should still be a link *)

type run =
  | Tsync of string  (** arguments after the binary *)
  | Shell of string  (** a plain command, for setup *)

type case = { name : string; command : run; expect : expect list }
type group = { title : string; cases : case list }

(** Run every case in order, checking each expectation and printing the output
    of any case that fails. The count asserted is the number of expectations
    declared, so a suite that stops early reports a short run. *)
val run_groups : group list -> unit

(** The binary under test, with [HOME] and the config redirected at this run.
    Output is stdout and stderr together. *)
val tsync : string -> string

val shell : string -> string
val contains : string -> string -> bool

(** A count from a summary line, or [-1] where the line says nothing of it. *)
val count : string -> string -> int
