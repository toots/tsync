(** cloud-files §5.2: the Windows session's end and screen lock, read from a
    hidden window's messages on a thread of its own, which the first hook added
    starts. Hooks run on that thread. Elsewhere no hook is ever called. *)

(** When the session ends: Windows ends the process seconds later. *)
val on_end : (unit -> unit) -> unit

(** When the screen locks. *)
val on_lock : (unit -> unit) -> unit
