(* The Linux vault keystore (security-model §10.6) against a Secret Service
   double on a private bus: argv.(1) is the double. *)

open Tsync_core
module Secret_service = Tsync_secret_service.Secret_service
module Keystore = Tsync_owner.Keystore

let dir = Filename.concat (Sys.getcwd ()) "secret-service"
let path name = Filename.concat dir name
let checks = ref 0

let check label ok =
  incr checks;
  Printf.printf "%s: %s\n" label (if ok then "ok" else "FAILED")

let show label f =
  incr checks;
  match f () with
    | v -> Printf.printf "%s: %s\n" label v
    | exception Fail.E f -> Printf.printf "%s: refused: %s\n" label f.reason

let refused label f =
  incr checks;
  Printf.printf "%s: %s\n" label
    (match f () with _ -> "answered" | exception Fail.E _ -> "refused")

let children = ref []

let () =
  at_exit (fun () ->
      List.iter
        (fun pid -> try Unix.kill pid Sys.sigkill with _ -> ())
        !children)

let spawn_reading program arguments =
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process program
      (Array.of_list (program :: arguments))
      Unix.stdin write_end Unix.stderr
  in
  children := pid :: !children;
  Unix.close write_end;
  let line = In_channel.input_line (Unix.in_channel_of_descr read_end) in
  (pid, Option.value line ~default:"")

let calls () = In_channel.with_open_text (path "calls") In_channel.input_lines

let entry = function
  | None -> "none"
  | Some (id, key) -> Printf.sprintf "%s, %d bytes" id (String.length key)

let () =
  Fs.mkdir_p ~perm:0o700 dir;
  Out_channel.with_open_text (path "bus.conf") (fun oc ->
      Printf.fprintf oc
        {|<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=%s</listen>
  <policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy>
</busconfig>
|}
        (path "bus"));
  Unix.putenv "DBUS_SESSION_BUS_ADDRESS" "";
  (* Unset, it would mean /run/user/<uid>: this machine's own session. *)
  Unix.putenv "XDG_RUNTIME_DIR" dir;
  Secret_service.register ();
  let ks = Option.get (Keystore.registered ()) in
  show "with no session bus yet" (fun () ->
      Rt.run_sync (fun () -> entry (ks.get ~domain:"photos")));
  let daemon, address =
    spawn_reading "dbus-daemon"
      ["--config-file=" ^ path "bus.conf"; "--nofork"; "--print-address=1"]
  in
  let double, ready =
    spawn_reading
      (Filename.concat Filename.current_dir_name Sys.argv.(1))
      [address; path "calls"; path "locked"]
  in
  check "the double is on the bus" (ready = "ready");
  Unix.putenv "DBUS_SESSION_BUS_ADDRESS" address;
  Rt.run_sync (fun () ->
      let domain = "photos" in
      let key = String.init 32 Char.chr in
      show "get before any put" (fun () -> entry (ks.get ~domain));
      ks.put ~domain ~key_id:"0123456789abcdef" ~key;
      show "get after a put" (fun () -> entry (ks.get ~domain));
      check "it reads back the same bytes"
        (ks.get ~domain = Some ("0123456789abcdef", key));
      ks.put ~domain ~key_id:"fedcba9876543210" ~key:(String.make 32 '\255');
      show "get after a put for another key id" (fun () ->
          entry (ks.get ~domain));
      check "the earlier item is deleted" (List.mem "Delete" (calls ()));
      ks.put ~domain:"photos/secret-key" ~key_id:"0000000000000001" ~key:"s";
      show "the secret key entry is apart" (fun () ->
          entry (ks.get ~domain:"photos/secret-key"));
      Out_channel.with_open_text (path "locked") ignore;
      show "get while locked" (fun () -> entry (ks.get ~domain));
      show "put while locked" (fun () ->
          ks.put ~domain ~key_id:"0123456789abcdef" ~key;
          "stored");
      show "delete while locked" (fun () ->
          ks.delete ~domain;
          "deleted");
      check "no prompt was ever shown" (not (List.mem "Prompt" (calls ())));
      Sys.remove (path "locked");
      show "get once unlocked" (fun () -> entry (ks.get ~domain));
      ks.delete ~domain;
      show "get after delete" (fun () -> entry (ks.get ~domain));
      Unix.kill double Sys.sigkill;
      ignore (Unix.waitpid [] double);
      refused "get with no Secret Service on the bus" (fun () -> ks.get ~domain));
  Unix.kill daemon Sys.sigterm;
  ignore (Unix.waitpid [] daemon);
  Printf.printf "%d checks\n" !checks
