(* How a server stops: asked over its own socket, told by the promise it was
   handed, or both, in either order. Whichever way, it returns, its socket is
   gone, and nothing escapes into the background, where Lwt's default would end
   the process. *)

open Lwt.Syntax
open Check

let socket_path =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-serve-%d.sock" (Unix.getpid ()))

let escaped = ref 0

let handler line =
  match Yojson.Safe.from_string line with
    | `Assoc [("action", `String "stop")] -> Lwt.return ({|{"ok":true}|}, `Stop)
    | _ -> Lwt.return ({|{"ok":true}|}, `Continue)

let rec await_listening tries =
  let probe = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Lwt.catch
    (fun () ->
      let* () = Lwt_unix.connect probe (Unix.ADDR_UNIX socket_path) in
      Lwt_unix.close probe)
    (function
      | Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _) when tries > 0
        ->
          let* () = Lwt_unix.close probe in
          let* () = Lwt_unix.sleep 0.01 in
          await_listening (tries - 1)
      | exn ->
          let* () = Lwt_unix.close probe in
          Lwt.fail exn)

let ask_stop () =
  let+ (_ : string) =
    Ipc_lwt.send_lwt ~timeout:1. ~socket_path {|{"action":"stop"}|}
  in
  ()

(* Returned within a second, the socket gone, and after a moment for anything
   left running to fail, nothing escaped. *)
let stopped server =
  let* finished =
    Lwt.pick
      [
        Lwt.map (fun () -> true) server;
        Lwt.map (fun () -> false) (Lwt_unix.sleep 1.);
      ]
  in
  let+ () = Lwt_unix.sleep 0.05 in
  check "it returns" finished;
  check "its socket is gone" (not (Sys.file_exists socket_path));
  check "nothing escaped" (!escaped = 0)

let () =
  (Lwt.async_exception_hook := fun _ -> incr escaped);
  Lwt_main.run
    (case "asked over its socket";
     let server = Ipc_lwt.serve ~path:socket_path handler in
     let* () = await_listening 100 in
     let* () = ask_stop () in
     let* () = stopped server in

     case "told by its promise, nobody asking";
     let until, wake = Lwt.wait () in
     let server = Ipc_lwt.serve ~until ~path:socket_path handler in
     let* () = await_listening 100 in
     Lwt.wakeup_later wake ();
     let* () = stopped server in

     case "asked, then told";
     let until, wake = Lwt.wait () in
     let server = Ipc_lwt.serve ~until ~path:socket_path handler in
     let* () = await_listening 100 in
     let* () = ask_stop () in
     Lwt.wakeup_later wake ();
     let* () = stopped server in

     report ~expected:9 ();
     Lwt.return_unit)
