(* The Linux user verifier (passwords/linux §4) against a polkit double on a
   private bus: argv.(1) is the double. *)

open Tsync_core

let dir = Filename.concat (Sys.getcwd ()) "polkit"
let path name = Filename.concat dir name

let start_bus () =
  Out_channel.with_open_text (path "bus.conf") (fun oc ->
      Printf.fprintf oc
        {|<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=%s</listen>
  <policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/><allow eavesdrop="false"/></policy>
</busconfig>
|}
        (path "bus"))

let spawn program arguments =
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process program
      (Array.of_list (program :: arguments))
      Unix.stdin write_end Unix.stderr
  in
  Unix.close write_end;
  let line =
    In_channel.input_line (Unix.in_channel_of_descr read_end)
    |> Option.value ~default:""
  in
  (pid, line)

let show = function
  | `Authorized -> "authorized"
  | `Dismissed -> "dismissed"
  | `Refused -> "refused"
  | `No_agent -> "no agent"

let ask address =
  match Tsync_polkit.Polkit.check ~address with
    | answer -> show answer
    | exception Fail.E { kind; _ } -> "fails " ^ Fail.code kind

let () =
  Fs.rm_rf dir;
  Fs.mkdir_p ~perm:0o700 dir;
  start_bus ();
  let daemon, address =
    spawn "dbus-daemon"
      ["--config-file=" ^ path "bus.conf"; "--nofork"; "--print-address=1"]
  in
  Fun.protect ~finally:(fun () ->
      (try Unix.kill daemon Sys.sigkill with _ -> ());
      Fs.rm_rf dir)
  @@ fun () ->
  Rt.run_sync (fun () ->
      Printf.printf "no authority on the bus: %s\n%!" (ask address);
      let double, ready =
        spawn
          (Filename.concat Filename.current_dir_name Sys.argv.(1))
          [address; path "asked"]
      in
      Printf.printf "the double: %s\n%!" ready;
      for _ = 1 to 4 do
        Printf.printf "%s\n%!" (ask address)
      done;
      Unix.kill double Sys.sigkill;
      ignore (Unix.waitpid [] double);
      In_channel.with_open_text (path "asked") In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (( <> ) "")
      |> List.sort_uniq compare
      |> List.iter (Printf.printf "asked: %s\n"))
