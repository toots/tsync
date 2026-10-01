open Tsync_core

let idle_limit = 60.
let default_stall = 60.
let excerpt_length = 200

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
}

let endpoint ?ca_file ?(max_connections = 32) url =
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
  }

let base_path e = e.base
let host e = e.host
let authority e = e.authority
let url e = e.url

type response = { status : int; headers : Codec.headers; body : Bigstring.t }

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

(* A pooled connection the server closed while idle fails on write or answers
   nothing at all; only then is the request sent again, on a fresh one. *)
let exchange e c ~meth ~target ~headers ~body ~reused =
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
  (try
     Transport.write_string c.t (Buffer.contents b);
     Option.iter (Transport.write c.t) body
   with e when reused && not (Rt.is_cancelled e) -> raise Dead_before_answer);
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
  let body = Codec.read_body ~limit:max_int c.reader framing in
  let keep =
    framing <> `Eof
    && (match Codec.header headers "connection" with
      | Some v -> String.lowercase_ascii v <> "close"
      | None -> true)
    && not (Codec.buffered c.reader)
  in
  ({ status; headers; body }, keep)

let request ?(stall = default_stall) ?(headers = fun () -> []) ?body e ~meth
    target =
  Rt.Semaphore.with_slot e.slots (fun () ->
      try
        Rt.with_stall_timeout stall (fun progress ->
            let headers = headers () in
            progress ();
            let attempt c ~reused =
              match exchange e c ~meth ~target ~headers ~body ~reused with
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
        | Rt.Timeout -> link "%s: no progress for %gs" e.host stall
        | Unix.Unix_error (err, _, _) ->
            link "%s: %s" e.host (Unix.error_message err)
        | Codec.Malformed m -> link "%s: %s" e.host m
        | Dead_before_answer -> link "%s closed the connection" e.host)
