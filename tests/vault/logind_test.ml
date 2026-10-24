(* The session lock auto-lock watches on Linux (vault §6.2) against a logind
   double on a private bus: argv.(1) is the double. *)

open Tsync_core

let dir = Filename.concat (Sys.getcwd ()) "logind"
let path name = Filename.concat dir name
let children = ref []

let () =
  at_exit (fun () ->
      List.iter
        (fun pid -> try Unix.kill pid Sys.sigkill with _ -> ())
        !children)

let spawn program arguments ~stdin =
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process program
      (Array.of_list (program :: arguments))
      stdin write_end Unix.stderr
  in
  children := pid :: !children;
  Unix.close write_end;
  In_channel.input_line (Unix.in_channel_of_descr read_end)
  |> Option.value ~default:""

let locks = Atomic.make 0

(* Polls the count, so a slow bus costs time and never a wrong verdict. *)
let reaches n seconds =
  let deadline = Unix.gettimeofday () +. seconds in
  let rec go () =
    Atomic.get locks >= n
    || Unix.gettimeofday () < deadline
       &&
       (Rt.sleep 0.05;
        go ())
  in
  go ()

let () =
  Fs.rm_rf dir;
  Fs.mkdir_p ~perm:0o700 dir;
  Out_channel.with_open_text (path "bus.conf") (fun oc ->
      Printf.fprintf oc
        {|<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=%s</listen>
  <policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/><allow eavesdrop="false"/></policy>
</busconfig>
|}
        (path "bus"));
  let address =
    spawn "dbus-daemon"
      ["--config-file=" ^ path "bus.conf"; "--nofork"; "--print-address=1"]
      ~stdin:Unix.stdin
  in
  let commands_read, commands = Unix.pipe ~cloexec:true () in
  Unix.clear_close_on_exec commands_read;
  let ready =
    spawn
      (Filename.concat Filename.current_dir_name Sys.argv.(1))
      [address] ~stdin:commands_read
  in
  Unix.close commands_read;
  Printf.printf "the double: %s\n%!" ready;
  Unix.putenv "DBUS_SYSTEM_BUS_ADDRESS" address;
  let send line =
    ignore
      (Unix.write_substring commands (line ^ "\n") 0 (String.length line + 1))
  in
  Rt.run_sync (fun () ->
      Tsync_logind.Logind.watch ~on_lock:(fun () -> Atomic.incr locks);
      (* The watcher subscribes in the background: the first sleep it hears is
         the sign that it listens. *)
      let rec first n =
        send "sleep true";
        if (not (reaches 1 0.5)) && n > 0 then first (n - 1)
      in
      first 20;
      Printf.printf "sleep, once it listens: %b\n" (Atomic.get locks >= 1);
      Atomic.set locks 0;
      send "lock mine";
      Printf.printf "our session locks: %b\n" (reaches 1 5.);
      Atomic.set locks 0;
      send "lock other";
      send "sleep false";
      send "lock mine";
      ignore (reaches 1 5.);
      Rt.sleep 0.5;
      Printf.printf "another user's lock and a wake, then ours: %d lock\n"
        (Atomic.get locks));
  Fs.rm_rf dir
