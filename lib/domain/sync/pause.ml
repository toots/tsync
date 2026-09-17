(* What a user means by "hold everything": no change to what this client holds,
   in either direction, until they say otherwise. A read is not held, being what
   somebody is waiting on rather than a change.

   One switch, so a caller cannot hold half of it, and the things it holds are
   told rather than asked: each is a loop of its own, and what it does while
   held is its own to say. *)
module type S = sig
  val set : bool -> unit
  val held : unit -> bool
end

module type HOLDABLE = sig
  val set_paused : bool -> unit
end

module Make (Uploads : HOLDABLE) (Metadata : HOLDABLE) : S = struct
  let switch = ref false

  let set held =
    switch := held;
    Uploads.set_paused held;
    Metadata.set_paused held

  let held () = !switch
end
