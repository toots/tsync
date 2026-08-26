(* Applied once: what a store has filed as corrupt is listed per chunk prefix,
   not per caller asking. *)
include Corruption
include Corruption.Over (Io_lwt.Core)
