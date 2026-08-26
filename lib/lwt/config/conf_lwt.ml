(* A domain's config on this process. {!Conf.S} leaves the monad its stores
   answer in open, so that everything reading a path rather than a key takes a
   config naming no scheduler; here it is Lwt. *)
module type S =
  Conf.S with type 'a io = 'a Lwt.t and module type Store = Backend_lwt.Store

(* What a config states about that choice, for the modules that build one. *)
module Monad = struct
  type 'a io = 'a Lwt.t

  module type Store = Backend_lwt.Store
end
