(* Whether the shared client reuses a connection.

   The figure that matters is TCP accepts, not requests: a driver that opens one
   connection per request pays a handshake — three round trips where one would
   do — and leaves a socket in TIME_WAIT for each, which is what caps a catch-up
   run however fast the link is.

   So the server here is a raw socket that counts accepts and speaks the least
   HTTP that keep-alive needs. Cohttp's own stateless client is measured beside
   the pooled one, because "one connection" only means something against a
   number that is not one.

   Nothing here reads a clock and the port is the kernel's choice, so the
   output is the same on any machine. *)

open Lwt.Syntax

let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

(* Requests here are bodiless, so the blank line ends one. *)
let read_request ic =
  let buf = Buffer.create 256 in
  let rec go () =
    let* line = Lwt_io.read_line_opt ic in
    match line with
      | None -> Lwt.return (Buffer.length buf > 0)
      | Some "" -> Lwt.return_true
      | Some l ->
          Buffer.add_string buf l;
          go ()
  in
  go ()

let serve ~accepts sock =
  let rec loop () =
    let* fd, _ = Lwt_unix.accept sock in
    incr accepts;
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd
    and oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
    (* One connection may carry many requests, which is the whole question. *)
    let rec pipeline () =
      let* more = read_request ic in
      if not more then Lwt_io.close ic
      else
        let* () = Lwt_io.write oc response in
        let* () = Lwt_io.flush oc in
        pipeline ()
    in
    Lwt.async (fun () -> Lwt.catch pipeline (fun _ -> Lwt.return_unit));
    loop ()
  in
  loop ()

let listener () =
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
  let* () = Lwt_unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) in
  Lwt_unix.listen sock 16;
  let port =
    match Lwt_unix.getsockname sock with
      | Unix.ADDR_INET (_, p) -> p
      | _ -> failwith "no port"
  in
  Lwt.return (sock, port)

let requests = 10
let row label v = Printf.printf "  %-16s %d\n" label v
let case title = Printf.printf "=== %s\n" title

let () =
  Lwt_main.run
    (let* sock, port = listener () in
     let accepts = ref 0 in
     Lwt.async (fun () ->
         Lwt.catch (fun () -> serve ~accepts sock) (fun _ -> Lwt.return_unit));
     let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/x" port) in
     let no_headers () = Lwt.return (Cohttp.Header.of_list []) in

     case "the pooled client";
     let client =
       Http_client_lwt.create ~name:"test" ~timeout:10. ~classify:Retry.classify
         ()
     in
     let answered = ref 0 in
     let rec go n =
       if n = 0 then Lwt.return_unit
       else
         let* resp, body =
           Http_client_lwt.call client ~headers:no_headers ~meth:`GET uri
         in
         if Http_client_lwt.is_ok resp && Bigstring.to_string body = "ok" then
           incr answered;
         go (n - 1)
     in
     let* () = go requests in
     row "requests" requests;
     row "answered" !answered;
     row "accepts" !accepts;

     (* Without this the count above would also hold for a client that never got
        the chance to reuse anything. *)
     case "cohttp's stateless client, for contrast";
     accepts := 0;
     let rec go n =
       if n = 0 then Lwt.return_unit
       else
         let* _resp, body = Cohttp_lwt_unix.Client.call `GET uri in
         let* _ = Cohttp_lwt.Body.to_string body in
         go (n - 1)
     in
     let* () = go requests in
     row "requests" requests;
     row "accepts" !accepts;

     Lwt.return_unit)
