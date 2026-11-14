open Tsync_core
module Transport = Tsync_http.Transport

type connection

external open_ : string -> int -> string -> string array option -> connection
  = "tsync_http_apple_open"

external wake_fd : connection -> Unix.file_descr = "tsync_http_apple_wake_fd"
external status : connection -> int = "tsync_http_apple_status"
external reason : connection -> string = "tsync_http_apple_reason"

external receive : connection -> Bigstring.t -> int -> int -> int
  = "tsync_http_apple_receive"

external send : connection -> Bigstring.t -> int -> int -> int
  = "tsync_http_apple_send"

external sent : connection -> int = "tsync_http_apple_sent"
external drain : connection -> unit = "tsync_http_apple_drain"
external close : connection -> unit = "tsync_http_apple_close"

(* The wake byte is drained before the state is read, so a handler that runs
   after the read leaves a byte for the wait. *)
let rec until ?timeout c ready =
  drain c;
  match ready () with
    | Some v -> v
    | None ->
        Rt.within `Immediate (fun () -> Rt.wait_readable ?timeout (wake_fd c));
        until ?timeout c ready

(* Pitfall A-11.6: a broken session reads as a broken socket to the client. *)
let broken c what =
  raise (Unix.Unix_error (Unix.ECONNRESET, "tls " ^ what, reason c))

let ders_of_pem pem =
  let rec go acc = function
    | "-----BEGIN CERTIFICATE-----" :: rest ->
        let rec body lines = function
          | "-----END CERTIFICATE-----" :: rest ->
              let base64 = String.concat "" (List.rev lines) in
              go
                (match Base64.decode base64 with
                  | Ok der -> der :: acc
                  | Error _ -> acc)
                rest
          | line :: rest -> body (line :: lines) rest
          | [] -> acc
        in
        body [] rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] (List.map String.trim (String.split_on_char '\n' pem))

let stream c =
  let read ?timeout buf off len =
    until ?timeout c (fun () ->
        match receive c buf off len with
          | -1 -> None
          | -2 -> broken c "read"
          | n -> Some n)
  in
  let piece = 65536 in
  let write ?timeout b =
    let rec go off =
      if off < Bigstring.length b then (
        let len = min piece (Bigstring.length b - off) in
        until ?timeout c (fun () ->
            match send c b off len with
              | 0 -> None
              | 1 -> Some ()
              | _ -> broken c "write");
        until ?timeout c (fun () ->
            match sent c with 0 -> None | 1 -> Some () | _ -> broken c "write");
        go (off + len))
    in
    go 0
  in
  Transport.make ~read ~write ~close:(fun () -> close c)

let open_connection ~host ~port (tls : Transport.tls) =
  let anchors =
    Option.map
      (fun f -> Array.of_list (ders_of_pem (Fs.read_file f)))
      tls.ca_file
  in
  let c =
    try open_ host port tls.host anchors
    with Failure why -> Transport.tls_failure tls.host why
  in
  match
    until c (fun () ->
        match status c with
          | 0 -> None
          | 1 -> Some ()
          | 2 -> Transport.untrusted tls.host (reason c)
          | _ -> Transport.tls_failure tls.host (reason c))
  with
    | () -> stream c
    | exception e ->
        close c;
        raise e

let () =
  Transport.register System
    { client = `Platform open_connection; server = None }
