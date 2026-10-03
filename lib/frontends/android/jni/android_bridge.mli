(** Registers the bridge's entries (android §5) for {!tsync_bridge.h}'s C calls.
*)

(** Tells the C bridge that this thread runs the OCaml runtime and that the
    bridge may answer: for a process whose runtime OCaml started. A host that
    starts the runtime from C calls [tsync_bridge_started] instead. *)
val started : unit -> unit
