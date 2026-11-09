open Tsync_core

type entry = { key : string; etag : string; body : Bigstring.t }

let magic = "tsyncidx1"
let max_bytes = 64 * 1024 * 1024
let max_children = 10_000

let encode entries =
  let size =
    List.fold_left
      (fun n e ->
        n + 12 + String.length e.key + String.length e.etag
        + Bigstring.length e.body)
      (String.length magic) entries
  in
  let b = Bigstring.create size in
  let pos = ref 0 in
  let put_string s =
    Bigstring.blit_from_bytes (Bytes.unsafe_of_string s) 0 b !pos
      (String.length s);
    pos := !pos + String.length s
  in
  let put_length n =
    let be = Bytes.create 4 in
    Bytes.set_int32_be be 0 (Int32.of_int n);
    put_string (Bytes.unsafe_to_string be)
  in
  let put_field_string s =
    put_length (String.length s);
    put_string s
  in
  put_string magic;
  List.iter
    (fun e ->
      put_field_string e.key;
      put_field_string e.etag;
      put_length (Bigstring.length e.body);
      Bigstring.blit ~src:e.body ~src_off:0 ~dst:b ~dst_off:!pos
        ~len:(Bigstring.length e.body);
      pos := !pos + Bigstring.length e.body)
    entries;
  b

let decode b =
  let n = Bigstring.length b in
  let m = String.length magic in
  if n < m || Bigstring.to_string ~len:m b <> magic then None
  else (
    let field pos =
      if pos + 4 > n then None
      else (
        let byte i = Char.code (Bigarray.Array1.get b (pos + i)) in
        let len =
          (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3
        in
        if len < 0 || len > n - pos - 4 then None
        else Some (Bigstring.sub b ~off:(pos + 4) ~len, pos + 4 + len))
    in
    let rec go pos acc =
      if pos = n then Some (List.rev acc)
      else (
        match field pos with
          | None -> None
          | Some (key, pos) -> (
              match field pos with
                | None -> None
                | Some (etag, pos) -> (
                    match field pos with
                      | None -> None
                      | Some (body, pos) ->
                          go pos
                            ({
                               key = Bigstring.to_string key;
                               etag = Bigstring.to_string etag;
                               body;
                             }
                            :: acc))))
    in
    go m [])
