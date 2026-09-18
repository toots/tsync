(* What a store's failure costs the client that asked.

   A failure waiting will not clear -- a rename whose source the store no longer
   has -- is answered by the proxy as the client's to settle, and the client's
   retry ladder leaves it alone. Answered as the server's instead, the same
   condition costs {!Retry.default_attempts} round trips and as many log lines,
   which is what a box emptying its trash while a peer published renames of
   those files was doing.

   The server is a raw socket that answers what the case says and counts what it
   was asked, so the assertion is the number of requests rather than a duration. *)

open Lwt.Syntax
open Check

let asked = ref 0
let answers : (string * string) list ref = ref []

(* Bodiless requests, so the blank line ends the head; a PUT carries one, which
   this reads by its length. *)
let read_request ic =
  (* Trimmed, because a header line ends [\r\n] and the reader keeps the
     [\r]: the blank line that ends the head reads as ["\r"]. *)
  let rec head acc =
    let* line = Lwt_io.read_line_opt ic in
    match Option.map String.trim line with
      | None -> Lwt.return None
      | Some "" -> Lwt.return (Some acc)
      | Some l -> head (l :: acc)
  in
  let+ lines = head [] in
  Option.map
    (fun lines ->
      List.fold_left
        (fun n l ->
          match String.lowercase_ascii l with
            | l when String.starts_with ~prefix:"content-length:" l ->
                int_of_string
                  (String.trim (String.sub l 15 (String.length l - 15)))
            | _ -> n)
        0 lines)
    lines

let serve sock =
  let rec loop () =
    let* fd, _ = Lwt_unix.accept sock in
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd
    and oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
    let rec answer () =
      let* body_length = read_request ic in
      match body_length with
        | None -> Lwt_io.close ic
        | Some length ->
            (* Only when there is one: a zero-length read waits for bytes that
               are not coming. *)
            let* (_ : string) =
              if length = 0 then Lwt.return "" else Lwt_io.read ~count:length ic
            in
            incr asked;
            let status, body =
              match !answers with
                | a :: rest ->
                    answers := rest;
                    a
                | [] -> ("500 Internal Server Error", "nothing planned")
            in
            let* () =
              Lwt_io.write oc
                (Printf.sprintf
                   "HTTP/1.1 %s\r\n\
                    Content-Length: %d\r\n\
                    Connection: keep-alive\r\n\
                    \r\n\
                    %s"
                   status (String.length body) body)
            in
            let* () = Lwt_io.flush oc in
            answer ()
    in
    Lwt.async (fun () -> Lwt.catch answer (fun _ -> Lwt.return_unit));
    loop ()
  in
  loop ()

let src = Stored_key.listed "tsync/dom/manifests/aaa/bbb-ccc"
let dst = Stored_key.listed "tsync/dom/manifests/aaa/ddd-eee"

let gone =
  "local copy: tsync/dom/manifests/aaa/bbb-ccc: No such file or directory"

(* The status is the client's to read; what the caller needs from it is the
   store's own words about what went wrong. *)
let mentions needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i =
    i + n <= h && (String.sub haystack i n = needle || at (i + 1))
  in
  at 0

let attempt ~plan store =
  asked := 0;
  answers := plan;
  let module B = (val store : Backend_lwt.Store) in
  Lwt.catch
    (fun () ->
      let+ () = B.copy ~src_key:src ~dst_key:dst () in
      "it answered")
    (fun exn -> Lwt.return (Retry.reason exn))

(* Bounded, so a server that does not answer fails the run rather than hanging
   it. *)
let within seconds what =
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout seconds what)
    (fun _ -> Lwt.return "it never answered")

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
     let store =
       Http_proxy_backend_lwt.make
         ~url:(Printf.sprintf "http://127.0.0.1:%d" port)
         ~secret:"s"
     in

     case "a failure the store says will not clear";
     let* why =
       within 10. (fun () -> attempt ~plan:[("409 Conflict", gone)] store)
     in
     step "%d request(s): %s" !asked why;
     check "it is asked once, and the reason reaches the caller"
       (!asked = 1 && mentions gone why);

     case "one it says is its own";
     let* why =
       within 30. @@ fun () ->
       attempt
         ~plan:
           [
             ("500 Internal Server Error", "disk fell over");
             ("500 Internal Server Error", "disk fell over");
             ("409 Conflict", gone);
           ]
         store
     in
     step "%d request(s): %s" !asked why;
     check
       "is waited out, and the ladder stops at the first that will not clear"
       (!asked = 3 && mentions gone why);
     report ~expected:2 ();
     Lwt.return_unit)
