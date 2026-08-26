include Wal

(* The queue over these records, shared with whoever drains them: one instance,
   so its settle registry and this log's id counter are each the only one. *)
module Q = Durable_queue_lwt.Make (Wal.Job)
include Wal.Make (Io_lwt.Core) (Q.Records)
