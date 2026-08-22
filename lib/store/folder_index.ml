(* Bodies keyed by the version the listing gave them.

   Framed rather than JSON because a body is bytes. The magic carries a version
   of its own: a reader that does not recognise it has no index rather than a
   broken one, which is what lets the format change without a migration. *)

let magic = "tsyncidx1"

type t = (string, string * string) Hashtbl.t

let empty : t = Hashtbl.create 1
let find t ~key ~etag =
  match Hashtbl.find_opt t key with
    | Some (recorded, body) when recorded = etag -> Some (Chunk.of_string body)
    | _ -> None

let add_be32 buf n =
  let byte shift = Char.chr ((n lsr shift) land 0xff) in
  Buffer.add_char buf (byte 24);
  Buffer.add_char buf (byte 16);
  Buffer.add_char buf (byte 8);
  Buffer.add_char buf (byte 0)

let add_field buf s =
  add_be32 buf (String.length s);
  Buffer.add_string buf s

let of_bodies entries =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf magic;
  List.iter
    (fun ((e : Backend.file_entry), body) ->
      match e.Backend.etag with
        | None -> ()
        | Some etag ->
            add_field buf e.Backend.key;
            add_field buf etag;
            add_field buf (Chunk.to_string body))
    entries;
  Chunk.of_string (Buffer.contents buf)

let of_chunk chunk =
  let s = Chunk.to_string chunk in
  let len = String.length s in
  if len < String.length magic || String.sub s 0 (String.length magic) <> magic
  then failwith "folder index: not one of ours";
  let be32_at pos =
    (Char.code s.[pos] lsl 24)
    lor (Char.code s.[pos + 1] lsl 16)
    lor (Char.code s.[pos + 2] lsl 8)
    lor Char.code s.[pos + 3]
  in
  let field pos =
    if pos + 4 > len then failwith "folder index: truncated";
    let n = be32_at pos in
    if n < 0 || pos + 4 + n > len then failwith "folder index: truncated";
    (String.sub s (pos + 4) n, pos + 4 + n)
  in
  let t = Hashtbl.create 64 in
  let rec go pos =
    if pos = len then t
    else begin
      let key, pos = field pos in
      let etag, pos = field pos in
      let body, pos = field pos in
      Hashtbl.replace t key (etag, body);
      go pos
    end
  in
  go (String.length magic)

(* A folder whose children are mostly covered already is not worth rewriting for
   the few that are not: the write costs every body again, where the reads it
   saves are only the ones it does not have. *)
let worth_writing ~covered ~total =
  total > 1 && covered * 4 < total * 3
