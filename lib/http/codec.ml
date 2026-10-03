open Tsync_core

type headers = (string * string) list

let header h k = List.assoc_opt k h

exception Malformed of string
exception Too_large

type reader = {
  t : Transport.t;
  buf : Bigstring.t;
  mutable pos : int;
  mutable len : int;
  progress : unit -> unit;
}

let reader ?(progress = ignore) t =
  { t; buf = Bigstring.create 65536; pos = 0; len = 0; progress }

let buffered r = r.pos < r.len

(* false at end of stream *)
let fill ?timeout r =
  if r.pos = r.len then (
    r.pos <- 0;
    r.len <- Transport.read ?timeout r.t r.buf 0 (Bigstring.length r.buf);
    if r.len > 0 then r.progress ();
    r.len > 0)
  else true

let index_newline r =
  let rec go i =
    if i >= r.len then None
    else if Bigarray.Array1.unsafe_get r.buf i = '\n' then Some i
    else go (i + 1)
  in
  go r.pos

let line ?timeout ~limit r =
  let b = Buffer.create 128 in
  let take n =
    Buffer.add_string b (Bigstring.to_string ~off:r.pos ~len:n r.buf);
    r.pos <- r.pos + n
  in
  let rec go () =
    if Buffer.length b > limit then raise Too_large;
    if not (fill ?timeout r) then
      if Buffer.length b = 0 then None
      else raise (Malformed "end of stream inside a line")
    else (
      match index_newline r with
        | Some i ->
            take (i - r.pos);
            r.pos <- r.pos + 1;
            let s = Buffer.contents b in
            let n = String.length s in
            Some
              (if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s)
        | None ->
            take (r.len - r.pos);
            go ())
  in
  go ()

let read_head ?timeout ~limit r =
  let budget = ref limit in
  let next () =
    match line ?timeout ~limit:!budget r with
      | Some l ->
          budget := !budget - String.length l - 2;
          if !budget < 0 then raise Too_large;
          Some l
      | None -> None
  in
  match next () with
    | None -> None
    | Some first ->
        let rec headers acc =
          match next () with
            | None -> raise (Malformed "end of stream inside the headers")
            | Some "" -> List.rev acc
            | Some l -> (
                match String.index_opt l ':' with
                  | Some i ->
                      let k =
                        String.lowercase_ascii (String.trim (String.sub l 0 i))
                      in
                      let v =
                        String.trim
                          (String.sub l (i + 1) (String.length l - i - 1))
                      in
                      headers ((k, v) :: acc)
                  | None -> raise (Malformed "a header line without ':'"))
        in
        Some (first, headers [])

(* Buffered bytes first, then straight from the transport into [dst]. *)
let exactly ?timeout r dst off n =
  let from_buffer = min n (r.len - r.pos) in
  Bigstring.blit ~src:r.buf ~src_off:r.pos ~dst ~dst_off:off ~len:from_buffer;
  r.pos <- r.pos + from_buffer;
  let rec go off n =
    if n > 0 then (
      let got = Transport.read ?timeout r.t dst off n in
      if got = 0 then raise (Malformed "end of stream inside a body");
      r.progress ();
      go (off + got) (n - got))
  in
  go (off + from_buffer) (n - from_buffer)

let piece ?timeout r n =
  let b = Bigstring.create n in
  exactly ?timeout r b 0 n;
  b

let read_body ?timeout ~limit r framing =
  match framing with
    | `Length n ->
        if n > limit then raise Too_large;
        piece ?timeout r n
    | `Eof ->
        let rec go acc total =
          if not (fill ?timeout r) then Bigstring.concat (List.rev acc)
          else (
            let n = r.len - r.pos in
            if total + n > limit then raise Too_large;
            go (piece ?timeout r n :: acc) (total + n))
        in
        go [] 0
    | `Chunked ->
        let rec chunks acc total =
          match line ?timeout ~limit:1024 r with
            | None -> raise (Malformed "end of stream inside a chunked body")
            | Some l -> (
                let size = List.hd (String.split_on_char ';' l) in
                match int_of_string_opt ("0x" ^ String.trim size) with
                  | Some 0 ->
                      let rec trailers () =
                        match line ?timeout ~limit:8192 r with
                          | Some "" | None -> ()
                          | Some _ -> trailers ()
                      in
                      trailers ();
                      Bigstring.concat (List.rev acc)
                  | Some n when n > 0 ->
                      if total + n > limit then raise Too_large;
                      let b = piece ?timeout r n in
                      ignore (line ?timeout ~limit:2 r);
                      chunks (b :: acc) (total + n)
                  | _ -> raise (Malformed "a bad chunk size"))
        in
        chunks [] 0

let framing h =
  match header h "transfer-encoding" with
    | Some te when String.lowercase_ascii te <> "identity" -> `Chunked
    | _ -> (
        match header h "content-length" with
          | Some v -> (
              let digits = String.trim v in
              match int_of_string_opt digits with
                | Some n
                  when digits <> ""
                       && String.for_all (fun c -> c >= '0' && c <= '9') digits
                  ->
                    `Length n
                | _ -> raise (Malformed "a bad content-length"))
          | None -> `Eof)

let write_head b first h =
  Buffer.add_string b first;
  Buffer.add_string b "\r\n";
  List.iter
    (fun (k, v) ->
      Buffer.add_string b k;
      Buffer.add_string b ": ";
      Buffer.add_string b v;
      Buffer.add_string b "\r\n")
    h;
  Buffer.add_string b "\r\n"

let days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

let months =
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
  |]

let http_date t =
  let t = Unix.gmtime t in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" days.(t.tm_wday)
    t.tm_mday months.(t.tm_mon) (t.tm_year + 1900) t.tm_hour t.tm_min t.tm_sec

let parse_http_date d =
  try
    Scanf.sscanf d "%_s %d %s %d %d:%d:%d GMT" (fun day mon year h m sec ->
        Option.bind
          (Array.find_index (String.equal mon) months)
          (fun i ->
            Option.map Ptime.to_float_s
              (Ptime.of_date_time ((year, i + 1, day), ((h, m, sec), 0)))))
  with _ -> None
