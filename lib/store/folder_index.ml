(* Bodies keyed by the version the listing gave them.

   Framed rather than JSON because a body is bytes. The magic carries a version
   of its own: a reader that does not recognise it has no index rather than a
   broken one, which is what lets the format change without a migration. *)

let magic = "tsyncidx1"

type t = (string, string * string) Hashtbl.t

let empty : t = Hashtbl.create 1
let find t ~key ~etag =
  match Hashtbl.find_opt t key with
    | Some (recorded, body) when recorded = etag -> Some body
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
            add_field buf body)
    entries;
  Buffer.contents buf

let of_string s =
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
    (* Compared against what is left rather than added to [pos]: a length near
       [max_int] overflows the sum on a 32-bit build, and the guard would pass a
       negative one to [String.sub], which raises [Invalid_argument] where this
       promises [Failure]. *)
    if n < 0 || n > len - pos - 4 then failwith "folder index: truncated";
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

(* Every body it covers is held on the heap twice over while it is built and
   again while it is read, on top of the listing and the parsed manifests the
   walk already holds. A folder past this is left to the reads it would have
   cost: the cache is worth having only where it is smaller than the thing it
   saves. *)
let max_children = 10_000

(* And a bound on what a reader will pull down, since the count above governs
   only what this build writes: an index left by another client, or by a build
   whose cap was different, is still on the store and is read whole. The listing
   names its size, so one past this is passed over without being fetched. *)
let max_bytes = 64 * 1024 * 1024

(* A folder whose children are mostly covered already is not worth rewriting for
   the few that are not: the write costs every body again, where the reads it
   saves are only the ones it does not have. *)
let worth_writing ~covered ~total =
  total > 1 && total <= max_children && covered * 4 < total * 3
