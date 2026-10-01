(** The owner jobs of 07 §2.5: long owner requests, run by the owner or, when
    none serves, by the command owning the domain for its run. *)

open Tsync_core

type copies = Probe | Outstanding | Retry_outstanding [@@deriving yojson]

type t =
  | Gc of { apply : bool; verify : bool; abort : bool; budget : float option }
  | Gc_copies of copies
  | Expire of { apply : bool; cutoff : float }
  | Purge of { apply : bool; path : string }
  | Import of {
      src : string;
      only : string list;
      exclude : string list;
      force_rehash : bool;
    }
  | Rsync of {
      src : string;
      src_in_domain : bool;
      dst : string;
      dst_in_domain : bool;
      move : bool;
      dry_run : bool;
    }
  | Mirror of { source : string option; manifests : bool; path : string option }
  | Integrity of {
      verify : bool;
      repair : bool;
      apply : bool;
      detail : bool;
      source : string option;
    }
[@@deriving yojson]

(** The command as typed, naming the job a conflicting one is refused for. *)
val kind : t -> string

type io = {
  out : string -> unit;  (** one line of the command's standard output *)
  narrate : Narrate.t;
  cancelled : unit -> bool;
}

(** The command's exit status; a refusal raises. [engine] is the owner's. *)
val run :
  io -> Tsync_domain.Domain.t -> (module Tsync_sync.Engine.S) -> t -> int
