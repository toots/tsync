(* A domain with no presentation of its own: the sync engine plus the IPC
   socket, and nothing else. There is no mount to serve and no extension to talk
   to — a client drives the domain entirely over IPC, which is what the Android
   DocumentsProvider does.

   Every other frontend serves IPC as a side effect of the thing it mounts, so
   on a platform with neither FUSE nor File Provider there is otherwise nothing
   for `tsync start` to start. *)

let implementation = "headless"
let is_local = Manifest.is_local

module Make (C : Conf.S) = struct
  module E = Domain_engine.Make (C)
  module F = E.F
  module Ih = E.Ih

  let hooks =
    Ih.
      {
        (* The client addresses files by storage key, not by a path in some
           mount it can see, so evict/restore/revert arrive already resolved. *)
        path_to_key = Fun.id;
        (* ponytail: single key only. FUSE walks a directory subtree here
           (fuse_fs.ml:184) because a user can point at a folder in Finder;
           lift that if a client ever offers the same gesture. *)
        evict = F.evict;
        restore = F.ensure_cached;
        (* Nothing here holds a materialised copy to invalidate: the client
           re-queries, and [sync --full] has already rebuilt the mirror before
           it signals us. *)
        changed = (fun _ -> ());
        full_resync = (fun () -> Lwt.return_unit);
        status_fields = (fun () -> []);
        (* Name the frontend these numbers belong to — a domain can run several,
           each with its own counters. *)
        stats_fields =
          (fun () -> ("frontend", `String implementation) :: E.stats_fields ());
        on_stop = (fun () -> ());
      }

  let start () =
    let open Lwt.Syntax in
    Lwt_main.run
      (let* () = E.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit) () in
       (* [Ipc.serve] returns when a client sends [stop]. *)
       let* () = Ipc.serve ~path:C.socket_path (Ih.handler hooks) in
       E.drain ())
end

let start_binding (b : Frontend.binding) =
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  let module C = (val b.Frontend.conf : Conf.S) in
  Log.set_prefix (Printf.sprintf "[%s] " C.domain_name);
  let module R = Make (C) in
  R.start ()

(* One process per domain, each with its own socket, as FUSE does — the last
   runs in this process, so the common single-domain case never forks. *)
let start bindings = Frontend.run_forked start_binding bindings

let register () =
  Frontend.register implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
