(* Whether the shared client reuses a connection.

   The figure that matters is TCP accepts, not requests: a driver that opens one
   connection per request pays a handshake — three round trips where one would
   do — and leaves a socket in TIME_WAIT for each, which is what caps a catch-up
   run however fast the link is.

   So the server here is a raw socket that counts accepts and speaks the least
   HTTP that keep-alive needs. Cohttp's own stateless client is measured beside
   the pooled one, because "one connection" only means something against a
   number that is not one. *)

open Lwt.Syntax
open Check

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

let () =
  Lwt_main.run
    (let* sock, port = listener () in
     let accepts = ref 0 in
     Lwt.async (fun () ->
         Lwt.catch (fun () -> serve ~accepts sock) (fun _ -> Lwt.return_unit));
     let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/x" port) in
     let no_headers () = Lwt.return (Cohttp.Header.of_list []) in

     case "the pooled client";
     let client = Http_client.create ~name:"test" ~timeout:10. () in
     let* oks = ref 0 |> Lwt.return in
     let rec go n =
       if n = 0 then Lwt.return_unit
       else
         let* resp, body =
           Http_client.call client ~headers:no_headers ~meth:`GET uri
         in
         if Http_client.is_ok resp && Chunk.to_string body = "ok" then incr oks;
         go (n - 1)
     in
     let* () = go requests in
     check "every request was answered"
       ~why:(fun () -> Printf.sprintf "%d of %d" !oks requests)
       (!oks = requests);
     let pooled = !accepts in
     check "and they shared one connection"
       ~why:(fun () ->
         Printf.sprintf "%d accepts for %d requests" pooled requests)
       (pooled = 1);

     (* Without this the assertion above would also hold for a client that never
        got the chance to reuse anything. *)
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
     check "opens one per request"
       ~why:(fun () ->
         Printf.sprintf "%d accepts for %d requests" !accepts requests)
       (!accepts = requests);

     report ~expected:3 ();
     Lwt.return_unit)
