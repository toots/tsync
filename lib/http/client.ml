open Tsync_core

let idle_limit = 60.
let default_stall = 60.
let excerpt_length = 200

(* A body goes to a file once it reaches this size: below it the file costs
   more than the memory it saves. *)
let spill_min = 256 * 1024

(* A mapping frees its file's blocks only when the collector finalizes it, and
   the collector does not count a mapping's size. *)
let collect_every = 256 * 1024 * 1024
let spilled_since_collection = Atomic.make 0

type conn = {
  t : Transport.t;
  reader : Codec.reader;
  mutable idle_since : float;
}

type endpoint = {
  host : string;
  port : int;
  authority : string;
  tls : Transport.tls option;
  base : string;
  url : string;
  idle : conn list Atomic.t;
  slots : Rt.Semaphore.t;
  spill : spill option;
}

and spill = { dir : string; prepared : bool Atomic.t }

(* An open file cannot be unlinked on Windows, so bodies stay in memory there. *)
let spill_of = function
  | Some dir when not Sys.win32 -> Some { dir; prepared = Atomic.make false }
  | _ -> None

(* A crash between creating a spill file and unlinking it leaves a temporary
   named after the dead process, which the sweep removes. *)
let prepare spill =
  if not (Atomic.exchange spill.prepared true) then (
    Fs.mkdir_p spill.dir;
    Fs.sweep_temps spill.dir)

let endpoint ?ca_file ?(max_connections = 32) ?spill url =
  let scheme, rest =
    match String.index_opt url ':' with
      | Some i when i + 2 < String.length url && String.sub url i 3 = "://" ->
          ( String.lowercase_ascii (String.sub url 0 i),
            String.sub url (i + 3) (String.length url - i - 3) )
      | _ -> Fail.invalid "%s: not an http(s) URL" url
  in
  let hostport, base =
    match String.index_opt rest '/' with
      | Some i ->
          (String.sub rest 0 i, String.sub rest i (String.length rest - i))
      | None -> (rest, "")
  in
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let host, port =
    let default = if scheme = "https" then 443 else 80 in
    if String.starts_with ~prefix:"[" hostport then (
      match String.index_opt hostport ']' with
        | Some j ->
            let h = String.sub hostport 1 (j - 1) in
            let p =
              String.sub hostport (j + 1) (String.length hostport - j - 1)
            in
            ( h,
              if String.starts_with ~prefix:":" p then
                int_of_string (String.sub p 1 (String.length p - 1))
              else default )
        | None -> Fail.invalid "%s: bad host" url)
    else (
      match String.rindex_opt hostport ':' with
        | Some j -> (
            match
              int_of_string_opt
                (String.sub hostport (j + 1) (String.length hostport - j - 1))
            with
              | Some p -> (String.sub hostport 0 j, p)
              | None -> Fail.invalid "%s: bad port" url)
        | None -> (hostport, default))
  in
  let tls =
    match scheme with
      | "https" -> Some { Transport.host; ca_file }
      | "http" -> None
      | _ -> Fail.invalid "%s: not an http(s) URL" url
  in
  let authority =
    let h = if String.contains host ':' then "[" ^ host ^ "]" else host in
    if port = if tls = None then 80 else 443 then h
    else Printf.sprintf "%s:%d" h port
  in
  {
    host;
    port;
    authority;
    tls;
    base;
    url;
    idle = Atomic.make [];
    slots = Rt.Semaphore.create ~name:("http " ^ host) max_connections;
    spill = spill_of spill;
  }

let base_path e = e.base
let host e = e.host
let authority e = e.authority
let url e = e.url

type response = {
  status : int;
  headers : Codec.headers;
  body : Bigstring.t;
  sent : float;
}

let excerpt body =
  let s = Bigstring.to_string ~len:(min (Bigstring.length body) 4096) body in
  let b = Buffer.create 64 in
  let space = ref false in
  String.iter
    (fun c ->
      if Buffer.length b < excerpt_length then (
        match c with
          | ' ' | '\t' | '\n' | '\r' -> space := true
          | c ->
              if !space && Buffer.length b > 0 then Buffer.add_char b ' ';
              space := false;
              Buffer.add_char b c))
    s;
  Buffer.contents b

let rec take_idle e =
  let l = Atomic.get e.idle in
  match l with
    | [] -> None
    | c :: rest ->
        if Atomic.compare_and_set e.idle l rest then
          if Rt.now () -. c.idle_since < idle_limit then Some c
          else (
            Transport.close c.t;
            take_idle e)
        else take_idle e

let rec put_idle e c =
  c.idle_since <- Rt.now ();
  let l = Atomic.get e.idle in
  if not (Atomic.compare_and_set e.idle l (c :: l)) then put_idle e c

let dial e progress =
  let t = Transport.connect ?tls:e.tls ~host:e.host ~port:e.port () in
  { t; reader = Codec.reader ~progress t; idle_since = Rt.now () }

exception Dead_before_answer

let link fmt = Fail.raise_ Fail.Link fmt

(* A failure of [pace] is the caller's, never a connection found dead. *)
exception Paced of exn

(* Waiting for the governor is not the link stalling, so it beats progress. *)
let paced ~stall ~progress pace remaining =
  let rec beat () =
    Rt.sleep (stall /. 4.);
    progress ();
    beat ()
  in
  match Rt.first [(fun () -> pace remaining); beat] with
    | granted -> granted
    | exception e when not (Rt.is_cancelled e) -> raise (Paced e)

(* 01 §10: request-body bytes accepted by the socket are progress, so a slow
   uplink sending a large body never reads as a stall. *)
let write_body ~stall ~progress ~pace t body =
  let piece = 65536 in
  let rec write off stop =
    if off < stop then (
      let len = min piece (stop - off) in
      Transport.write t (Bigstring.sub body ~off ~len);
      progress ();
      write (off + len) stop)
  in
  let rec go off =
    let remaining = Bigstring.length body - off in
    if remaining > 0 then (
      let granted =
        match pace with
          | Some pace ->
              max 1 (min remaining (paced ~stall ~progress pace remaining))
          | None -> remaining
      in
      write off (off + granted);
      go (off + granted))
  in
  go 0

let open_spill_file spill =
  prepare spill;
  let path = Fs.temp_in spill.dir in
  let fd = Fs.openfile ~perm:0o600 path [O_RDWR; O_CREAT; O_EXCL] in
  Fs.unlink_quiet path;
  fd

let collect_if_spilled_much bytes =
  if
    Atomic.fetch_and_add spilled_since_collection bytes + bytes >= collect_every
  then (
    Atomic.set spilled_since_collection 0;
    Gc.major ())

(* 01 §10: a body is written to an unlinked file once it reaches [spill_min],
   and answered as its mapping, so it never sits in memory. *)
let spill_body spill ~max_body reader framing =
  let held = ref [] and held_bytes = ref 0 in
  let file = ref None and written = ref 0 in
  let to_file fd view =
    let len = Bigstring.length view in
    Fs.pwrite_all fd view ~boff:0 ~len ~off:!written;
    written := !written + len
  in
  let emit view =
    match !file with
      | Some fd -> to_file fd view
      | None ->
          let copy = Bigstring.create (Bigstring.length view) in
          Bigstring.blit ~src:view ~src_off:0 ~dst:copy ~dst_off:0
            ~len:(Bigstring.length view);
          held := copy :: !held;
          held_bytes := !held_bytes + Bigstring.length view;
          if !held_bytes >= spill_min then (
            let fd = open_spill_file spill in
            file := Some fd;
            List.iter (to_file fd) (List.rev !held);
            held := [])
  in
  Fun.protect
    ~finally:(fun () -> Option.iter Fs.close !file)
    (fun () ->
      Codec.stream_body ~limit:max_body reader framing emit;
      match !file with
        | None -> Bigstring.concat (List.rev !held)
        | Some fd ->
            collect_if_spilled_much !written;
            Fs.map_fd fd)

let exchange ~stall ~max_body e c ~progress ~pace ~meth ~target ~headers ~body
    ~reused =
  let b = Buffer.create 256 in
  let head =
    [("host", e.authority)]
    @ headers
    @
      match body with
      | Some s -> [("content-length", string_of_int (Bigstring.length s))]
      | None ->
          if meth = "POST" || meth = "PUT" then [("content-length", "0")]
          else []
  in
  Codec.write_head b
    (Printf.sprintf "%s %s HTTP/1.1" meth (e.base ^ target))
    head;
  let sent = Rt.now () in
  (try
     Transport.write_string c.t (Buffer.contents b);
     Option.iter (write_body ~stall ~progress ~pace c.t) body
   with
    | Paced e -> raise e
    | e when reused && not (Rt.is_cancelled e) -> raise Dead_before_answer);
  let head =
    match Codec.read_head ~limit:65536 c.reader with
      | Some h -> h
      | None ->
          if reused then raise Dead_before_answer
          else link "%s closed the connection" e.host
      | exception Unix.Unix_error ((ECONNRESET | EPIPE), _, _) when reused ->
          raise Dead_before_answer
  in
  let status_line, headers = head in
  let status =
    match String.split_on_char ' ' status_line with
      | v :: code :: _ when String.starts_with ~prefix:"HTTP/1." v -> (
          match int_of_string_opt code with
            | Some c -> c
            | None -> link "%s: bad status line" e.host)
      | _ -> link "%s: bad status line" e.host
  in
  let framing =
    if
      meth = "HEAD" || status = 204 || status = 304
      || (status >= 100 && status < 200)
    then `Length 0
    else Codec.framing headers
  in
  let small = match framing with `Length n -> n < spill_min | _ -> false in
  let body =
    match e.spill with
      | Some spill when status / 100 = 2 && not small ->
          spill_body spill ~max_body c.reader framing
      | _ -> Codec.read_body ~limit:max_body c.reader framing
  in
  let keep =
    framing <> `Eof
    && (match Codec.header headers "connection" with
      | Some v -> String.lowercase_ascii v <> "close"
      | None -> true)
    && not (Codec.buffered c.reader)
  in
  ({ status; headers; body; sent }, keep)

(* A pooled connection the server closed while idle fails on write or answers
   nothing at all; only then is the request sent again, on a fresh one, with
   headers made again so that a signature is as fresh as the attempt. *)
let request ?(stall = default_stall) ?(max_body = max_int)
    ?(headers = fun () -> []) ?pace ?body e ~meth target =
  Rt.Semaphore.with_slot e.slots (fun () ->
      try
        Rt.with_stall_timeout stall (fun progress ->
            let attempt c ~reused =
              let headers = headers () in
              progress ();
              match
                exchange ~stall ~max_body e c ~progress ~pace ~meth ~target
                  ~headers ~body ~reused
              with
                | r, keep ->
                    if keep then put_idle e c else Transport.close c.t;
                    r
                | exception ex ->
                    Transport.close c.t;
                    raise ex
            in
            match take_idle e with
              | Some c -> (
                  let c = { c with reader = Codec.reader ~progress c.t } in
                  try attempt c ~reused:true
                  with Dead_before_answer ->
                    attempt (dial e progress) ~reused:false)
              | None -> attempt (dial e progress) ~reused:false)
      with
        | Rt.Timeout ->
            Fail.raise_ ~stalled:true Fail.Link "%s: no progress for %gs" e.host
              stall
        | Unix.Unix_error (err, _, _) ->
            link "%s: %s" e.host (Unix.error_message err)
        | Codec.Malformed m -> link "%s: %s" e.host m
        | Codec.Too_large ->
            Fail.corrupt "%s: its answer is larger than this client accepts"
              e.host
        | Dead_before_answer -> link "%s closed the connection" e.host)
