open Tsync_core

type limits = {
  header_bytes : int;
  header_timeout : float;
  idle_timeout : float;
  keepalive_timeout : float;
  max_connections : int;
}

let default_limits =
  {
    header_bytes = 16384;
    header_timeout = 30.;
    idle_timeout = 60.;
    keepalive_timeout = 75.;
    max_connections = 512;
  }

type request = {
  meth : string;
  target : string;
  path : string;
  query : string;
  headers : Codec.headers;
  peer : string;
  body_length : [ `Length of int | `Chunked | `Eof ];
}

type body =
  | Empty
  | String of string
  | Bigstring of Bigstring.t
  | Stream of ((Bigstring.t -> unit) -> unit)

type response = { status : int; headers : Codec.headers; body : body }

let text ?(headers = []) status msg =
  {
    status;
    headers = ("content-type", "text/plain; charset=utf-8") :: headers;
    body = String (msg ^ "\n");
  }

exception Body_too_large

type t = {
  listeners : Unix.file_descr list;
  stopping : unit Rt.Promise.t;
  finished : unit Rt.Promise.t;
  connections : int Atomic.t;
  requests : int Atomic.t;
  conns : Transport.t list Atomic.t;
}

let reason = function
  | 200 -> "OK"
  | 204 -> "No Content"
  | 206 -> "Partial Content"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 405 -> "Method Not Allowed"
  | 409 -> "Conflict"
  | 410 -> "Gone"
  | 413 -> "Content Too Large"
  | 414 -> "URI Too Long"
  | 416 -> "Range Not Satisfiable"
  | 431 -> "Request Header Fields Too Large"
  | 500 -> "Internal Server Error"
  | 502 -> "Bad Gateway"
  | 503 -> "Service Unavailable"
  | _ -> "Status"

let http_date () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
    [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |].(t.tm_wday)
    t.tm_mday
    [|
      "Jan";
      "Feb";
      "Mar";
      "Apr";
      "May";
      "Jun";
      "Jul";
      "Aug";
      "Sep";
      "Oct";
      "Nov";
      "Dec";
    |].(t.tm_mon)
    (t.tm_year + 1900) t.tm_hour t.tm_min t.tm_sec

let write_response lim conn ~head_only ~close r =
  let b = Buffer.create 256 in
  let framing =
    match r.body with
      | Empty -> [("content-length", "0")]
      | String s -> [("content-length", string_of_int (String.length s))]
      | Bigstring b -> [("content-length", string_of_int (Bigstring.length b))]
      | Stream _ -> [("transfer-encoding", "chunked")]
  in
  Codec.write_head b
    (Printf.sprintf "HTTP/1.1 %d %s" r.status (reason r.status))
    ((("date", http_date ()) :: r.headers)
    @ framing
    @ if close then [("connection", "close")] else []);
  let write s = Transport.write_string ~timeout:lim.idle_timeout conn s in
  let write_body b = Transport.write ~timeout:lim.idle_timeout conn b in
  match r.body with
    | String s when not head_only ->
        Buffer.add_string b s;
        write (Buffer.contents b)
    | Bigstring body when not head_only ->
        write (Buffer.contents b);
        write_body body
    | Stream f when not head_only ->
        write (Buffer.contents b);
        f (fun piece ->
            if Bigstring.length piece > 0 then (
              write (Printf.sprintf "%x\r\n" (Bigstring.length piece));
              write_body piece;
              write "\r\n"));
        write "0\r\n\r\n"
    | _ -> write (Buffer.contents b)

let split_target target =
  match String.index_opt target '?' with
    | Some i ->
        ( String.sub target 0 i,
          String.sub target (i + 1) (String.length target - i - 1) )
    | None -> (target, "")

let serve_conn lim handle conn requests =
  let reader = Codec.reader conn in
  let peer = Transport.peer conn in
  let rec loop first =
    let timeout = if first then lim.header_timeout else lim.keepalive_timeout in
    match Codec.read_head ~timeout ~limit:lim.header_bytes reader with
      | None -> ()
      | exception Codec.Too_large ->
          write_response lim conn ~head_only:false ~close:true
            (text 431 "request headers too large")
      | Some (line, headers) -> (
          match String.split_on_char ' ' line with
            | [meth; target; version]
              when String.starts_with ~prefix:"HTTP/1." version ->
                let body_length =
                  try Codec.framing headers
                  with Codec.Malformed _ -> `Length (-1)
                in
                let body_length =
                  match body_length with `Eof -> `Length 0 | f -> f
                in
                let path, query = split_target target in
                let req =
                  { meth; target; path; query; headers; peer; body_length }
                in
                let consumed = ref (body_length = `Length 0) in
                let read_body ~limit =
                  if !consumed then Bigstring.empty
                  else (
                    consumed := true;
                    (match body_length with
                      | `Length n when n > limit -> raise Body_too_large
                      | `Length n when n < 0 ->
                          raise (Codec.Malformed "bad length")
                      | _ -> ());
                    if Codec.header headers "expect" = Some "100-continue" then
                      Transport.write_string ~timeout:lim.idle_timeout conn
                        "HTTP/1.1 100 Continue\r\n\r\n";
                    try
                      Codec.read_body ~timeout:lim.idle_timeout ~limit reader
                        body_length
                    with Codec.Too_large -> raise Body_too_large)
                in
                Atomic.incr requests;
                let r =
                  Fun.protect
                    ~finally:(fun () -> Atomic.decr requests)
                    (fun () ->
                      try handle req read_body with
                        | Body_too_large -> text 413 "too large"
                        | Codec.Malformed _ -> text 400 "bad request"
                        | e when not (Rt.is_cancelled e) ->
                            Log.err "http %s %s: %s" meth path
                              (Printexc.to_string e);
                            text 500 "internal error")
                in
                let close =
                  (not !consumed)
                  || Codec.header headers "connection" = Some "close"
                  || version = "HTTP/1.0"
                in
                write_response lim conn ~head_only:(meth = "HEAD") ~close r;
                if not close then loop false
            | _ ->
                write_response lim conn ~head_only:false ~close:true
                  (if String.length line > 8192 then text 414 "target too long"
                   else text 400 "bad request"))
  in
  loop true

let rec accept_loop t lim handle lfd =
  let ready =
    Rt.first
      [
        (fun () ->
          Rt.wait_readable lfd;
          true);
        (fun () ->
          Rt.Promise.await t.stopping;
          false);
      ]
  in
  if ready then (
    if Atomic.get t.connections >= lim.max_connections then Rt.sleep 0.05
    else (
      match Unix.accept ~cloexec:true lfd with
        | fd, _ ->
            let conn = Transport.of_fd fd in
            Atomic.incr t.connections;
            let rec add () =
              let l = Atomic.get t.conns in
              if not (Atomic.compare_and_set t.conns l (conn :: l)) then add ()
            in
            let rec remove () =
              let l = Atomic.get t.conns in
              if
                not
                  (Atomic.compare_and_set t.conns l
                     (List.filter (( != ) conn) l))
              then remove ()
            in
            add ();
            Rt.spawn ~name:"http connection" (fun () ->
                Fun.protect
                  ~finally:(fun () ->
                    remove ();
                    Transport.close conn;
                    Atomic.decr t.connections)
                  (fun () ->
                    try serve_conn lim handle conn t.requests
                    with e when not (Rt.is_cancelled e) ->
                      Log.debug "http %s: %s" (Transport.peer conn)
                        (Printexc.to_string e)))
        | exception
            Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR | ECONNABORTED), _, _)
          ->
            ()
        | exception e when not (Rt.is_cancelled e) ->
            Log.once "http accept" Log.Warn "http accept: %s"
              (Printexc.to_string e);
            Rt.sleep 0.1);
    accept_loop t lim handle lfd)

let bind addr =
  let fd =
    Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) SOCK_STREAM 0
  in
  Unix.setsockopt fd SO_REUSEADDR true;
  (match addr with
    | ADDR_INET (a, _)
      when Unix.domain_of_sockaddr addr = PF_INET6 && a = Unix.inet6_addr_any ->
        Unix.setsockopt fd IPV6_ONLY true
    | _ -> ());
  Unix.bind fd addr;
  Unix.listen fd 128;
  Unix.set_nonblock fd;
  fd

let serve ?(limits = default_limits) addrs handle =
  let listeners = List.map bind addrs in
  let t =
    {
      listeners;
      stopping = Rt.Promise.create ();
      finished = Rt.Promise.create ();
      connections = Atomic.make 0;
      requests = Atomic.make 0;
      conns = Atomic.make [];
    }
  in
  let running = Atomic.make (List.length listeners) in
  List.iter
    (fun lfd ->
      Rt.spawn ~name:"http accept" (fun () ->
          Fun.protect
            ~finally:(fun () ->
              Unix.close lfd;
              if Atomic.fetch_and_add running (-1) = 1 then
                Rt.Promise.resolve t.finished ())
            (fun () -> accept_loop t limits handle lfd)))
    listeners;
  t

let close ?(grace = Stop.grace) t =
  ignore (Rt.Promise.try_resolve t.stopping ());
  if t.listeners <> [] then Rt.Promise.await t.finished;
  let deadline = Rt.now () +. grace in
  while Atomic.get t.requests > 0 && Rt.now () < deadline do
    Rt.sleep 0.05
  done;
  List.iter Transport.shutdown (Atomic.get t.conns)

let in_flight t = Atomic.get t.requests
let addresses t = List.map Unix.getsockname t.listeners
