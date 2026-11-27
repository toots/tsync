(** Runs the owner jobs of {!Tsync_protocol.Job}. *)

open Tsync_core

include module type of struct
  include Tsync_protocol.Job
end

type io = {
  out : string -> unit;  (** one line of the command's standard output *)
  narrate : Narrate.t;
  cancelled : unit -> bool;
}

(** The command's exit status; a refusal raises. [engine] is the owner's. *)
val run :
  io -> Tsync_domain.Domain.t -> (module Tsync_sync.Engine.S) -> t -> int
