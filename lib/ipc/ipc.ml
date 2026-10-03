open Tsync_core

type json = Yojson.Safe.t

let max_line = 1 lsl 20
let line_deadline = 10.
let max_connections = 256
let subscriber_backlog = 256
let request_deadline = 30.
let client_deadline = request_deadline +. 5.
let advisory_deadline = 2.
let liveness_interval = 10.
let liveness_deadline = 5.
let ok fields = `Assoc (("ok", `Bool true) :: fields)

let failure (f : Fail.t) =
  `Assoc
    ([
       ("ok", `Bool false);
       ("code", `String (Fail.code f.kind));
       ("error", `String f.reason);
     ]
    @
      match f.retry_after with
      | Some s -> [("retryAfter", `Float s)]
      | None -> [])

let invalid reason = failure (Fail.make Fail.Invalid reason)

let field j k =
  match j with
    | `Assoc l -> (
        match List.assoc_opt k l with Some (`String s) -> Some s | _ -> None)
    | _ -> None

(* A write to a peer that left raises EPIPE instead of killing the process. *)

let retry_io = function
  | Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> true
  | _ -> false

module Line = struct
  type t = { fd : Unix.file_descr; buf : Buffer.t; chunk : Bytes.t }

  exception Too_long

  let make fd =
    Unix.set_nonblock fd;
    { fd; buf = Buffer.create 256; chunk = Bytes.create 65536 }

  let take t =
    let s = Buffer.contents t.buf in
    match String.index_opt s '\n' with
      | None -> None
      | Some i when i > max_line -> raise Too_long
      | Some i ->
          Buffer.clear t.buf;
          Buffer.add_substring t.buf s (i + 1) (String.length s - i - 1);
          Some (String.sub s 0 i)

  let remaining = function
    | None -> None
    | Some limit -> Some (Float.max 0. (limit -. Rt.now ()))

  (* Once a line has begun, its rest must arrive within [line_deadline];
     [deadline] bounds the whole wait. [None] at end of stream. *)
  let read ?deadline t =
    let rec go started =
      match take t with
        | Some l -> Some l
        | None -> (
            if Buffer.length t.buf > max_line then raise Too_long;
            let started =
              match started with
                | None when Buffer.length t.buf > 0 -> Some (Rt.now ())
                | s -> s
            in
            let limit =
              match (deadline, Option.map (( +. ) line_deadline) started) with
                | Some a, Some b -> Some (Float.min a b)
                | a, None -> a
                | None, b -> b
            in
            Rt.wait_readable ?timeout:(remaining limit) t.fd;
            match Unix.read t.fd t.chunk 0 (Bytes.length t.chunk) with
              | 0 -> None
              | n ->
                  Buffer.add_subbytes t.buf t.chunk 0 n;
                  go started
              | exception e when retry_io e -> go started)
    in
    Rt.within `Immediate (fun () -> go None)

  let write ?deadline t s =
    let s = s ^ "\n" in
    let rec go off =
      if off < String.length s then (
        match Unix.write_substring t.fd s off (String.length s - off) with
          | n -> go (off + n)
          | exception e when retry_io e ->
              Rt.within `Immediate (fun () ->
                  Rt.wait_writable ?timeout:(remaining deadline) t.fd;
                  go off))
    in
    go 0
end

type answer =
  | Reply of json
  | Subscribe of string * json * json list
  | Stream of ((json -> unit) -> json)

type conn = {
  line : Line.t;
  mutable idle_since : float option;  (** [None] while busy or subscribed *)
  mutable answering : bool;
}

type subscriber = { queue : json Queue.t; wake : Rt.Signal.t }

type server = {
  path : string;
  lfd : Unix.file_descr;
  m : Mutex.t;
  mutable conns : conn list;
  topics : (string, subscriber list) Hashtbl.t;
  stopping : unit Rt.Promise.t;
  finished : unit Rt.Promise.t;
  mutable closing : bool;
  left : Rt.Signal.t;
}

(* sun_path, NUL included. *)
let max_path = if Fs.is_macos then 103 else 107

let check_length path =
  if String.length path > max_path then
    Fail.raise_ Fail.Invalid
      "socket path %s is longer than the %d bytes a Unix socket address holds"
      path max_path

let check_dir dir =
  Fs.mkdir_p (Filename.dirname dir);
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (EEXIST, _, _) -> ());
  let st = Unix.lstat dir in
  if
    st.st_kind <> S_DIR
    || st.st_uid <> Unix.getuid ()
    || st.st_perm land 0o077 <> 0
  then
    Fail.raise_ Fail.Denied
      "%s must be a directory owned by this user with mode 0700; refusing to \
       serve"
      dir

let subscribers t topic =
  Mutex.protect t.m (fun () ->
      List.length (Option.value ~default:[] (Hashtbl.find_opt t.topics topic)))

let publish t topic ev =
  Mutex.protect t.m (fun () ->
      let subs = Option.value ~default:[] (Hashtbl.find_opt t.topics topic) in
      List.iter
        (fun s ->
          Queue.push ev s.queue;
          if Queue.length s.queue > subscriber_backlog then (
            ignore (Queue.pop s.queue);
            Log.once ("ipc backlog " ^ t.path) Log.Warn
              "%s: a subscriber of %s is not reading; dropping its oldest \
               events"
              t.path topic);
          Rt.Signal.broadcast s.wake)
        subs;
      List.length subs)

let set_topic t topic f =
  Mutex.protect t.m (fun () ->
      let subs = Option.value ~default:[] (Hashtbl.find_opt t.topics topic) in
      Hashtbl.replace t.topics topic (f subs))

let stream_events t c topic first =
  let s =
    { queue = Queue.of_seq (List.to_seq first); wake = Rt.Signal.create () }
  in
  set_topic t topic (fun subs -> s :: subs);
  Fun.protect
    ~finally:(fun () -> set_topic t topic (List.filter (( != ) s)))
    (fun () ->
      let rec loop () =
        let v = Rt.Signal.version s.wake in
        match Mutex.protect t.m (fun () -> Queue.take_opt s.queue) with
          | Some ev ->
              Line.write
                ~deadline:(Rt.now () +. line_deadline)
                c.line (Yojson.Safe.to_string ev);
              loop ()
          | None -> (
              match
                Rt.first
                  [
                    (fun () ->
                      Rt.Signal.wait ~since:v s.wake;
                      `Wake);
                    (fun () ->
                      Rt.wait_readable c.line.fd;
                      `Readable);
                  ]
              with
                | `Wake -> loop ()
                | `Readable -> (
                    match
                      Unix.read c.line.fd c.line.chunk 0
                        (Bytes.length c.line.chunk)
                    with
                      | 0 -> ()
                      | _ -> loop ()
                      | exception e when retry_io e -> loop ()))
      in
      loop ())

(* A client that went away does not stop the work it asked for (07 §4.3): its
   lines are dropped from then on. *)
let stream_lines c =
  let gone = ref false in
  fun j ->
    if not !gone then (
      try
        Line.write
          ~deadline:(Rt.now () +. line_deadline)
          c.line (Yojson.Safe.to_string j)
      with e when not (Rt.is_cancelled e) -> gone := true)

let parse l =
  match Yojson.Safe.from_string l with
    | `Assoc _ as j -> Ok j
    | _ -> Error (invalid "expected a JSON object")
    | exception Yojson.Json_error _ -> Error (invalid "invalid JSON")

(* 01 §6.5: a connection is read, parsed and answered as non-blocking I/O, and
   only the handler leaves for the class its request names. The liveness
   answer (07 §4.3) never leaves. *)
let serve_conn t c ~execution handler =
  let reply j = Line.write c.line (Yojson.Safe.to_string j) in
  let handler req =
    if field req "action" = Some "ping" then Reply (ok [])
    else Rt.within (execution req) (fun () -> handler req)
  in
  let rec loop () =
    let open_ =
      Mutex.protect t.m (fun () ->
          c.answering <- false;
          if not t.closing then c.idle_since <- Some (Rt.now ());
          not t.closing)
    in
    match if open_ then Line.read c.line else None with
      | None -> ()
      | Some l -> (
          Mutex.protect t.m (fun () ->
              c.idle_since <- None;
              c.answering <- true);
          match parse l with
            | Error r ->
                reply r;
                loop ()
            | Ok req -> (
                match handler req with
                  | Reply r ->
                      reply r;
                      loop ()
                  | Subscribe (topic, r, first) ->
                      reply r;
                      Mutex.protect t.m (fun () -> c.answering <- false);
                      stream_events t c topic first
                  | Stream run ->
                      reply
                        (Rt.within (execution req) (fun () ->
                             run (stream_lines c)));
                      loop ()
                  | exception e ->
                      reply (failure (Fail.classify e));
                      loop ()))
  in
  try loop () with
    | Line.Too_long -> (
        try reply (invalid "request line too long") with _ -> ())
    | e ->
        Rt.within `Threaded (fun () ->
            Log.debug "%s: connection closed: %s" t.path (Printexc.to_string e))

let unregister t c =
  Mutex.protect t.m (fun () -> t.conns <- List.filter (( != ) c) t.conns);
  Rt.Signal.broadcast t.left

(* Called under [t.m]: a connection leaves the list before its descriptor is
   closed, so this never reaches a reused descriptor. *)
let hang_up c = try Unix.shutdown c.line.fd SHUTDOWN_ALL with _ -> ()

(* 01 §11: at the bound, the connection idle the longest makes room; with none
   idle the newcomer is refused. *)
let admit t fd ~execution handler =
  if (try Fs.peer_uid fd with _ -> -1) <> Unix.getuid () then (
    Unix.close fd;
    Rt.within `Threaded (fun () ->
        Log.once ("ipc peer " ^ t.path) Log.Warn
          "%s: refused a connection from another user" t.path))
  else (
    let c = { line = Line.make fd; idle_since = None; answering = false } in
    let admitted =
      Mutex.protect t.m (fun () ->
          if List.length t.conns >= max_connections then (
            match
              List.filter_map
                (fun c -> Option.map (fun s -> (s, c)) c.idle_since)
                t.conns
              |> List.sort (fun (a, _) (b, _) -> Float.compare a b)
            with
              | (_, oldest) :: _ ->
                  hang_up oldest;
                  t.conns <- c :: t.conns;
                  true
              | [] -> false)
          else (
            t.conns <- c :: t.conns;
            true))
    in
    if not admitted then Unix.close fd
    else
      Rt.spawn ~name:"ipc connection" ~execution:`Immediate (fun () ->
          Fun.protect
            ~finally:(fun () ->
              unregister t c;
              Unix.close fd)
            (fun () -> serve_conn t c ~execution handler)))

let rec accept_loop t ~execution handler =
  let ready =
    Rt.first
      [
        (fun () ->
          Rt.wait_readable t.lfd;
          true);
        (fun () ->
          Rt.Promise.await t.stopping;
          false);
      ]
  in
  if ready then (
    (match Unix.accept ~cloexec:true t.lfd with
      | fd, _ -> admit t fd ~execution handler
      | exception e when retry_io e -> ()
      | exception Unix.Unix_error (ECONNABORTED, _, _) -> ()
      | exception e when not (Rt.is_cancelled e) ->
          Rt.within `Threaded (fun () ->
              Log.once ("ipc accept " ^ t.path) Log.Warn "%s: accept: %s" t.path
                (Printexc.to_string e));
          Rt.sleep 0.1);
    accept_loop t ~execution handler)

let serve ?(execution = fun _ -> `Threaded) ~path handler =
  Tsync_core.Fs.ignore_sigpipe ();
  check_dir (Filename.dirname path);
  check_length path;
  (try Unix.unlink path with Unix.Unix_error (ENOENT, _, _) -> ());
  let lfd = Unix.socket ~cloexec:true PF_UNIX SOCK_STREAM 0 in
  let umask = Unix.umask 0o177 in
  Fun.protect
    ~finally:(fun () -> ignore (Unix.umask umask))
    (fun () -> Unix.bind lfd (ADDR_UNIX path));
  Unix.listen lfd 64;
  Unix.set_nonblock lfd;
  let t =
    {
      path;
      lfd;
      m = Mutex.create ();
      conns = [];
      topics = Hashtbl.create 4;
      stopping = Rt.Promise.create ();
      finished = Rt.Promise.create ();
      closing = false;
      left = Rt.Signal.create ();
    }
  in
  Rt.spawn ~name:("ipc " ^ path) ~execution:`Immediate (fun () ->
      Fun.protect
        ~finally:(fun () ->
          Unix.close lfd;
          (try Unix.unlink path with Unix.Unix_error _ -> ());
          Rt.Promise.resolve t.finished ())
        (fun () -> accept_loop t ~execution handler));
  t

let close_grace = 5.

(* A connection answering a request, such as the one asking to stop, gets
   [close_grace] to write its reply. *)
let close t =
  ignore (Rt.Promise.try_resolve t.stopping ());
  Rt.Promise.await t.finished;
  let answering () =
    Mutex.protect t.m (fun () ->
        t.closing <- true;
        List.iter (fun c -> if not c.answering then hang_up c) t.conns;
        List.exists (fun c -> c.answering) t.conns)
  in
  let deadline = Rt.now () +. close_grace in
  let rec wait () =
    let v = Rt.Signal.version t.left in
    if answering () && Rt.now () < deadline then (
      (try
         Rt.with_timeout
           (deadline -. Rt.now ())
           (fun () -> Rt.Signal.wait ~since:v t.left)
       with Rt.Timeout -> ());
      wait ())
  in
  wait ();
  Mutex.protect t.m (fun () -> List.iter hang_up t.conns)

exception Not_serving of string

let () =
  Printexc.register_printer (function
    | Not_serving path -> Some ("nothing serves " ^ path)
    | _ -> None)

module Client = struct
  type t = Line.t

  (* A server that stopped accepting fills its backlog: a blocking connect
     would then pin a scheduler thread, so the attempt is bounded. *)
  let connect_timeout = 5.

  let connect ?(timeout = connect_timeout) path =
    Tsync_core.Fs.ignore_sigpipe ();
    check_length path;
    let fd = Unix.socket ~cloexec:true PF_UNIX SOCK_STREAM 0 in
    Unix.set_nonblock fd;
    let deadline = Rt.now () +. timeout in
    let rec attempt () =
      match Unix.connect fd (ADDR_UNIX path) with
        | () -> ()
        | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _)
          when Rt.now () < deadline ->
            Rt.sleep 0.05;
            attempt ()
        | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) ->
            Fail.raise_ Fail.Deadline "%s accepts no connection" path
        | exception Unix.Unix_error (EINPROGRESS, _, _) -> (
            (try Rt.wait_writable ~timeout:(deadline -. Rt.now ()) fd
             with Rt.Timeout ->
               Fail.raise_ Fail.Deadline "%s accepts no connection" path);
            match Unix.getsockopt_error fd with
              | None -> ()
              | Some e -> raise (Unix.Unix_error (e, "connect", path)))
    in
    match attempt () with
      | () -> Line.make fd
      | exception Unix.Unix_error ((ENOENT | ECONNREFUSED | ENOTSOCK), _, _) ->
          Unix.close fd;
          raise (Not_serving path)
      | exception e ->
          Unix.close fd;
          raise e

  let read ?timeout t =
    let deadline = Option.map (( +. ) (Rt.now ())) timeout in
    match Line.read ?deadline t with
      | None -> None
      | Some l -> (
          match Yojson.Safe.from_string l with
            | j -> Some j
            | exception Yojson.Json_error _ ->
                Fail.raise_ Fail.Corrupt "a reply that is not JSON")
      | exception Rt.Timeout ->
          Fail.raise_ Fail.Deadline "no answer within %.0fs"
            (Option.value ~default:0. timeout)

  let request ?(timeout = client_deadline) t req =
    Line.write ~deadline:(Rt.now () +. timeout) t (Yojson.Safe.to_string req);
    match read ~timeout t with
      | Some j -> j
      | None -> Fail.raise_ Fail.Link "the server closed the connection"

  let next ?timeout t = read ?timeout t
  let close (t : t) = Unix.close t.fd
end

let with_client path f =
  let c = Client.connect path in
  Fun.protect ~finally:(fun () -> Client.close c) (fun () -> f c)

let call ?timeout path req =
  with_client path (fun c -> Client.request ?timeout c req)

let ping = `Assoc [("action", `String "ping")]

let streamed j =
  match j with `Assoc l -> List.mem_assoc "stream" l | _ -> false

let call_stream path req ~on_line =
  with_client path (fun c ->
      Line.write c (Yojson.Safe.to_string req);
      Rt.first
        [
          (fun () ->
            let rec next () =
              match Client.read c with
                | Some j when streamed j ->
                    on_line j;
                    next ()
                | Some j -> j
                | None ->
                    Fail.raise_ Fail.Link "the server closed the connection"
            in
            next ());
          (fun () ->
            Rt.within `Direct @@ fun () ->
            let rec probe () =
              Rt.sleep liveness_interval;
              (try ignore (call ~timeout:liveness_deadline path ping)
               with e when not (Rt.is_cancelled e) ->
                 Fail.raise_ Fail.Deadline
                   "%s stopped answering its liveness probe" path);
              probe ()
            in
            probe ());
        ])

let call_bulk path req = call_stream path req ~on_line:ignore

let advisory path req =
  try ignore (call ~timeout:advisory_deadline path req) with
    | Not_serving _ -> ()
    | e when not (Rt.is_cancelled e) ->
        let f = Fail.classify e in
        Log.once
          ("ipc advisory " ^ path ^ Fail.kind_name f.kind)
          Log.Info "%s: %s" path f.reason
