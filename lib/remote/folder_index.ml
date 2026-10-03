type entry = { key : string; etag : string; body : string }

let magic = "tsyncidx1"
let max_bytes = 64 * 1024 * 1024
let max_children = 10_000

let encode entries =
  let b = Buffer.create 4096 in
  Buffer.add_string b magic;
  let field s =
    Buffer.add_int32_be b (Int32.of_int (String.length s));
    Buffer.add_string b s
  in
  List.iter
    (fun e ->
      field e.key;
      field e.etag;
      field e.body)
    entries;
  Buffer.contents b

let decode s =
  let n = String.length s in
  let m = String.length magic in
  if n < m || String.sub s 0 m <> magic then None
  else (
    let field pos =
      if pos + 4 > n then None
      else (
        let len = Int32.to_int (String.get_int32_be s pos) in
        if len < 0 || pos + 4 + len > n then None
        else Some (String.sub s (pos + 4) len, pos + 4 + len))
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
                      | Some (body, pos) -> go pos ({ key; etag; body } :: acc))
              ))
    in
    go m [])
