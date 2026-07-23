open Lwt.Syntax

(* The per-domain sync engine shared by all frontends: the upload queue, file
   ops, journal/IPC handler and the change poller. A frontend instantiates one
   [Make(C)] per domain and calls [start] on its own Lwt loop, supplying the
   callbacks that differ between presentations; everything below is identical
   across frontends, so it lives here once. *)
module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Ih = Ipc_handler.Make (C) (F)
  module Sp = Sync_poller.Make (C) (F)

  let start ?on_changed ~on_cursor ~on_upload_done () =
    let* () = Local.init ~cache_root:C.cache_root ~domain_name:C.domain_name in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor ~on_upload_done;
    Sp.start ?on_changed ();
    Lwt.return_unit

  let drain = Sq.drain

  let stats_fields () =
    [
      ("pendingUploads", `Int (Sq.pending ()));
      ("uploadsCompleted", `Int (Sq.completed_count ()));
    ]
end
