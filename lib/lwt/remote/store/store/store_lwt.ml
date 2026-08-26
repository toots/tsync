(* The batched read, resolved: which drivers have a native one, and how wide the
   fan-out is, are settled once where the stores are built. *)
module Batched = struct
  type pool = Io_lwt.Bounded.t

  module Make = Backend_lwt.Batched
end

include Store.Over (Io_lwt.Core) (Batched)
