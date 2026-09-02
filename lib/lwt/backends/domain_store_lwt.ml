(* A domain's stores presented as one, over this process's queues, locks and
   drain hooks. *)
module Deferred = Deferred.Over (Io_lwt.Core) (Durable_queue_lwt) (Io_lwt.Lock)

include
  Domain_store.Over (Io_lwt.Core) (Durable_queue_lwt) (Io_lwt.Lock)
    (Backend_lwt)
    (struct
      type slots = Io_lwt.Bounded.t

      module Batched = Backend_lwt.Batched
    end)
