type headers = (string * string) list

let header h k = List.assoc_opt k h

exception Malformed of string
exception Too_large

type reader = {
  t : Transport.t;
  buf : Bytes.t;
  mutable pos : int;
  mutable len : int;
  progress : unit -> unit;
}

let reader ?(progress = ignore) t =
  { t; buf = Bytes.create 65536; pos = 0; len = 0; progress }

let buffered r = r.pos < r.len

(* false at end of stream *)
let fill ?timeout r =
  if r.pos = r.len then (
    r.pos <- 0;
    r.len <- Transport.read ?timeout r.t r.buf 0 (Bytes.length r.buf);
    if r.len > 0 then r.progress ();
    r.len > 0)
  else true

let line ?timeout ~limit r =
  let b = Buffer.create 128 in
  let rec go () =
    if Buffer.length b > limit then raise Too_large;
    if not (fill ?timeout r) then
      if Buffer.length b = 0 then None
      else raise (Malformed "end of stream inside a line")
    else (
      match Bytes.index_from_opt r.buf r.pos '\n' with
        | Some i when i < r.len ->
            Buffer.add_subbytes b r.buf r.pos (i - r.pos);
            r.pos <- i + 1;
            let s = Buffer.contents b in
            let n = String.length s in
            Some
              (if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s)
        | _ ->
            Buffer.add_subbytes b r.buf r.pos (r.len - r.pos);
            r.pos <- r.len;
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

let exactly ?timeout r b n =
  let rec go n =
    if n > 0 then (
      if not (fill ?timeout r) then
        raise (Malformed "end of stream inside a body");
      let k = min n (r.len - r.pos) in
      Buffer.add_subbytes b r.buf r.pos k;
      r.pos <- r.pos + k;
      go (n - k))
  in
  go n

let read_body ?timeout ~limit r framing =
  let b = Buffer.create 4096 in
  (match framing with
    | `Length n ->
        if n > limit then raise Too_large;
        exactly ?timeout r b n
    | `Eof ->
        while fill ?timeout r do
          Buffer.add_subbytes b r.buf r.pos (r.len - r.pos);
          r.pos <- r.len;
          if Buffer.length b > limit then raise Too_large
        done
    | `Chunked ->
        let rec chunks () =
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
                      trailers ()
                  | Some n when n > 0 ->
                      if Buffer.length b + n > limit then raise Too_large;
                      exactly ?timeout r b n;
                      ignore (line ?timeout ~limit:2 r);
                      chunks ()
                  | _ -> raise (Malformed "a bad chunk size"))
        in
        chunks ());
  Buffer.contents b

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
