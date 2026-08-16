(* A listing, as bytes.

   A fixed header followed by self-delimiting records, read through a mapping:
   every field is at a known offset from the record before it, and a key is a
   substring only when a caller asks for one.

   Layout (little-endian, offsets in bytes):
   {v
     0   8   magic "tsyncsp1"
     8   4   format   int32
     12  4   reserved int32
     16      records, each:
               0   4   key_len  int32
               4   8   size     int64
               12      key bytes
   v}
   The record count is not in the header: writing it would mean rewriting a file
   the mapping discipline forbids rewriting, and records being self-delimiting
   the walk does not need it. It is carried in the value instead. *)

open Lwt.Syntax

exception Out_of_order of { spool : string; previous : string; next : string }

let () =
  Printexc.register_printer (function
    | Out_of_order { spool; previous; next } ->
        Some
          (Printf.sprintf "%s listed %S after %S, which is not ascending" spool
             next previous)
    | _ -> None)

let magic = "tsyncsp1"
let format_version = 1
let header_bytes = 16
let record_header_bytes = 12

type t = {
  file : Spool.t;
  label : string;
  mutable previous : string option;
  mutable written : int;
}

type sealed = {
  s_path : string;
  s_label : string;
  map : Local_io.buffer;
  s_count : int;
}

type cursor = { c_map : Local_io.buffer; limit : int; mutable off : int }

let header () =
  let b = Bytes.create header_bytes in
  Bytes.blit_string magic 0 b 0 8;
  Bytes.set_int32_le b 8 (Int32.of_int format_version);
  Bytes.set_int32_le b 12 0l;
  Bytes.to_string b

let create ~dir ~label =
  let* file = Spool.create ~dir ~name:"listing" in
  let+ () = Spool.append file (header ()) in
  { file; label; previous = None; written = 0 }

let encode_record buf ~key ~size =
  let head = Bytes.create record_header_bytes in
  Bytes.set_int32_le head 0 (Int32.of_int (String.length key));
  Bytes.set_int64_le head 4 (Int64.of_int size);
  Buffer.add_bytes buf head;
  Buffer.add_string buf key

let add t entries =
  let buf = Buffer.create 4096 in
  let rec encode = function
    | [] -> None
    | (e : Backend.file_entry) :: rest -> (
        let key = e.Backend.key in
        match t.previous with
          | Some p when String.compare key p < 0 -> Some (p, key)
          | Some p when String.equal key p -> encode rest
          | _ ->
              encode_record buf ~key ~size:e.Backend.size;
              t.previous <- Some key;
              t.written <- t.written + 1;
              encode rest)
  in
  match encode entries with
    | Some (previous, next) ->
        Lwt.fail (Out_of_order { spool = t.label; previous; next })
    | None ->
        if Buffer.length buf = 0 then Lwt.return_unit
        else Spool.append t.file (Buffer.contents buf)

let discard t = Spool.drop t.file

let seal t =
  let* body = Spool.seal t.file in
  let len = Chunk.length body in
  if len < header_bytes then
    Lwt.fail
      (Invalid_argument
         (Printf.sprintf "listing spool %s is %d bytes" t.label len))
  else begin
    let map = Chunk.buffer body in
    if Bigstringaf.substring map ~off:0 ~len:8 <> magic then
      Lwt.fail
        (Invalid_argument ("listing spool " ^ t.label ^ " has a foreign magic"))
    else if Int32.to_int (Bigstringaf.get_int32_le map 8) <> format_version then
      Lwt.fail
        (Invalid_argument
           ("listing spool " ^ t.label ^ " is of another format version"))
    else
      Lwt.return
        {
          s_path = Spool.path t.file;
          s_label = t.label;
          map;
          s_count = t.written;
        }
  end

let count s = s.s_count
let remove s = Fs_util.unlink_quiet s.s_path

let cursor s =
  { c_map = s.map; limit = Bigstringaf.length s.map; off = header_bytes }

let at_end c = c.off >= c.limit
let key_len c = Int32.to_int (Bigstringaf.get_int32_le c.c_map c.off)
let key_at c = c.off + record_header_bytes
let size c = Int64.to_int (Bigstringaf.get_int64_le c.c_map (c.off + 4))
let key c = Bigstringaf.substring c.c_map ~off:(key_at c) ~len:(key_len c)
let advance c = c.off <- c.off + record_header_bytes + key_len c

let key_is_dir c =
  let len = key_len c in
  len > 0 && Bigstringaf.unsafe_get c.c_map (key_at c + len - 1) = '/'

(* [memcmp] over the common length then the lengths, which is what
   [String.compare] does and what the stores order by. *)
let compare a b =
  let la = key_len a and lb = key_len b in
  let c =
    Bigstringaf.memcmp a.c_map (key_at a) b.c_map (key_at b) (min la lb)
  in
  if c <> 0 then c else Int.compare la lb

let sweep ~dir = Spool.reap ~dir
