include Backend

(* Applied once: the drivers that register themselves, the hooks a composite
   settles through, and the pool the batched reads come out of are each the only
   one in this process. *)
include Backend.Make (Io_lwt.Core) (Io_lwt.Bounded)
