(* A domain's stores presented as one, over this process's queues, locks and
   drain hooks. *)
include
  Domain_store.Over (Io_lwt.Core) (Durable_queue_lwt) (Io_lwt.Lock)
    (Backend_lwt)

module Deferred = Dt
