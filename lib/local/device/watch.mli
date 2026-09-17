(** Being told a directory changed, rather than asking.

    A hint and nothing more: what is watched is the directory, so an event says
    a neighbour may have moved and never which object or whether its bytes
    differ. The caller reads and compares either way — which is what lets this
    be missing entirely, on a platform with no implementation or a filesystem
    whose writers are somewhere else. *)

type t

(** A watcher on [dir], or [None] where the platform will not give one: [dir] is
    not there yet, or it is a network mount, where nothing arrives for a writer
    on another machine. Both are the caller's cue to keep asking on a timer, so
    neither is worth an exception.

    Non-recursive: a change inside a subdirectory of [dir] is not one of these.
*)
val open_dir : string -> t option

(** Readable once something in the directory has changed. Wait on it with
    whatever the caller's scheduler uses; this library does not wait. *)
val fd : t -> Unix.file_descr

(** Consume whatever made {!fd} readable, so the next wait is about the next
    change, answering whether any of it was a change at all.

    What an event names answers no question the caller does not have to ask the
    store regardless, with one exception it cannot do without: a name this
    process writes for its own scratch. A read takes a reflink snapshot through
    a temp file in the object's own directory, so reporting those wakes the
    reader that made them, which reads again. [false] is that and nothing else.

    A platform whose events carry no name answers [true] throughout. *)
val drain : t -> bool

(** Nobody in the daemon calls this: a store watches one directory for the life
    of the process, so there is nothing to reclaim. It is here because a watcher
    that can be opened and not closed is not a resource. *)
val close : t -> unit
