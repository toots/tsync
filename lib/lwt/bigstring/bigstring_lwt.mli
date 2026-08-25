(** {!Bigstring}, and the one thing a buffer needs a scheduler for.

    A module that only maps and hashes bytes takes {!Bigstring} and links no
    scheduler; one that writes them takes this. *)

include module type of Bigstring

(** [write_to ~path t ~offset] puts [t] into [path] at [offset]. An empty [t]
    still makes [path] appear. *)
val write_to : path:string -> t -> offset:int -> unit Lwt.t
