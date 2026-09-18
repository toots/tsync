(* What the client's timeout is a timeout on.

   A body takes as long as the link it crosses, which is nobody's failure: eight
   8 MiB reads sharing 1.5 MB/s each ran past a sixty-second budget and were
   fetched again, for hours. Only an answer that has stopped arriving is stuck.

   The server is a raw socket that sends what the case says at the pace it says,
   every gap a fraction of the timeout or several of them, so a loaded machine
   does not change which side of it a case falls on. *)

open Lwt.Syntax
open Check

let timeout = 0.5
let piece = String.make 1000 'x'

type plan = {
  head_after : float;  (** silence before the status line *)
  pieces : int;  (** sent, of the six announced *)
  gap : float;  (** between them *)
}

let plan = ref { head_after = 0.; pieces = 6; gap = 0. }

let rec drain_head ic =
  let* line = Lwt_io.read_line_opt ic in
  match Option.map String.trim line with
    | None | Some "" -> Lwt.return_unit
    | Some _ -> drain_head ic

let answer fd =
  let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd
  and oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
  let p = !plan in
  let* () = drain_head ic in
  let* () = Lwt_unix.sleep p.head_after in
  let* () =
    Lwt_io.write oc
      (Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n"
         (6 * String.length piece))
  in
  let rec send n =
    if n = 0 then Lwt.return_unit
    else
      let* () = Lwt_io.write oc piece in
      let* () = Lwt_io.flush oc in
      let* () = Lwt_unix.sleep p.gap in
      send (n - 1)
  in
  let* () = send p.pieces in
  (* Held open: a body cut short by a close is a different failure from one
     that goes quiet. *)
  let* (_ : string option) = Lwt_io.read_line_opt ic in
  Lwt_io.close oc

let serve sock =
  let rec loop () =
    let* fd, _ = Lwt_unix.accept sock in
    Lwt.async (fun () ->
        Lwt.catch (fun () -> answer fd) (fun _ -> Lwt.return_unit));
    loop ()
  in
  loop ()

let ask uri p =
  plan := p;
  let client =
    Http_client_lwt.create ~name:"test" ~timeout
      ~classify:(fun _ -> Retry.Permanent)
      ()
  in
  let started = Unix.gettimeofday () in
  let+ outcome =
    Lwt.catch
      (fun () ->
        let+ _, body =
          Http_client_lwt.call client
            ~headers:(fun () -> Lwt.return (Cohttp.Header.init ()))
            ~meth:`GET uri
        in
        `Body (Bigstring.length body))
      (fun exn ->
        Lwt.return
          (if Io_lwt.Clock.is_timeout exn then `Timed_out
           else `Failed (Printexc.to_string exn)))
  in
  (outcome, Unix.gettimeofday () -. started)

let show = function
  | `Body n -> Printf.sprintf "%d bytes" n
  | `Timed_out -> "timed out"
  | `Failed why -> why

let () =
  Lwt_main.run
    (let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
     let* () =
       Lwt_unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
     in
     Lwt_unix.listen sock 8;
     let port =
       match Lwt_unix.getsockname sock with
         | Unix.ADDR_INET (_, p) -> p
         | _ -> 0
     in
     Lwt.async (fun () -> serve sock);
     let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/x" port) in

     case "a body that takes three timeouts to arrive, a piece at a time";
     let* outcome, took = ask uri { head_after = 0.; pieces = 6; gap = 0.25 } in
     check "arrives whole" ~why:(fun () -> show outcome) (outcome = `Body 6000);
     check "having taken longer than the timeout, which was the point"
       ~why:(fun () -> Printf.sprintf "%.2fs" took)
       (took > 2. *. timeout);

     case "a body that stops arriving";
     let* outcome, took = ask uri { head_after = 0.; pieces = 2; gap = 0.05 } in
     check "is given up on" ~why:(fun () -> show outcome) (outcome = `Timed_out);
     check "one timeout after its last byte, not one after its first"
       ~why:(fun () -> Printf.sprintf "%.2fs" took)
       (took >= timeout && took < 6. *. timeout);

     case "an answer that never starts";
     let* outcome, _ = ask uri { head_after = 30.; pieces = 0; gap = 0. } in
     check "is given up on too"
       ~why:(fun () -> show outcome)
       (outcome = `Timed_out);
     Lwt.return_unit);
  report ~expected:5 ()
