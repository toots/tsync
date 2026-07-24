(* ── Client ──────────────────────────────────────────────────────────────── *)

let send ~socket_path cmd =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX socket_path);
  let ic = Unix.in_channel_of_descr fd in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc (cmd ^ "\n");
  flush oc;
  let resp = input_line ic in
  Unix.close fd;
  resp

(* ── Auto-evict user feature ─────────────────────────────────────────────── *)

(* Per-domain: the marker is named after the domain so auto-evict can be toggled
   independently for each. *)
let auto_evict_marker ~data_dir ~domain =
  Filename.concat data_dir ("auto-evict-" ^ domain)

let auto_evict_enabled ~data_dir ~domain =
  Sys.file_exists (auto_evict_marker ~data_dir ~domain)

let handle_auto_evict ~data_dir ~domain = function
  | "on" ->
      (try close_out (open_out (auto_evict_marker ~data_dir ~domain))
       with _ -> ());
      "OK"
  | "off" ->
      (try Unix.unlink (auto_evict_marker ~data_dir ~domain)
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      "OK"
  | "status" -> if auto_evict_enabled ~data_dir ~domain then "on" else "off"
  | _ -> "ERROR expected on|off|status"

let notify ~path msg =
  try
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    (try
       Unix.connect fd (Unix.ADDR_UNIX path);
       let oc = Unix.out_channel_of_descr fd in
       output_string oc (msg ^ "\n");
       flush oc
     with _ -> ());
    Unix.close fd
  with _ -> ()

let notify_evict ~path key = notify ~path ("EVICT " ^ key)
let notify_restore ~path key = notify ~path ("RESTORE " ^ key)
let notify_uploaded ~path key = notify ~path ("UPLOADED " ^ key)
let notify_changed ~path key = notify ~path ("CHANGED " ^ key)
let notify_resync ~path = notify ~path "RESYNC"

(* ── Server ──────────────────────────────────────────────────────────────── *)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let serve ~path handler =
  let open Lwt.Syntax in
  let dir = Filename.dirname path in
  mkdir_p dir;
  (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let stopped, wake_stop = Lwt.wait () in
  (* Each connection is served on its own Lwt task, so a slow request (e.g. a
     large restore) never blocks other clients (e.g. status). *)
  let handle_client (ic, oc) =
    Lwt.catch
      (fun () ->
        let* line = Lwt_io.read_line ic in
        let* resp, action = handler line in
        let* () = Lwt_io.write_line oc resp in
        let* () = Lwt_io.flush oc in
        if action = `Stop && Lwt.state stopped = Lwt.Sleep then
          Lwt.wakeup_later wake_stop ();
        Lwt.return_unit)
      (fun _ -> Lwt.return_unit)
  in
  let addr = Unix.ADDR_UNIX path in
  let* server =
    Lwt_io.establish_server_with_client_address addr (fun _addr channels ->
        handle_client channels)
  in
  let* () = stopped in
  let* () = Lwt_io.shutdown_server server in
  (try Unix.unlink path with _ -> ());
  Lwt.return_unit
