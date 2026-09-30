let crc_table =
  Array.init 256 (fun n ->
      let c = ref (Int32.of_int n) in
      for _ = 0 to 7 do
        c :=
          if Int32.logand !c 1l <> 0l then
            Int32.logxor 0xEDB88320l (Int32.shift_right_logical !c 1)
          else Int32.shift_right_logical !c 1
      done;
      !c)

let crc_update crc s off len =
  let c = ref (Int32.lognot crc) in
  for i = off to off + len - 1 do
    let idx =
      Int32.to_int
        (Int32.logand
           (Int32.logxor !c (Int32.of_int (Char.code (String.unsafe_get s i))))
           0xffl)
    in
    c := Int32.logxor crc_table.(idx) (Int32.shift_right_logical !c 8)
  done;
  Int32.lognot !c

type entry = {
  name : string;
  crc : int32;
  size : int;
  offset : int;
  mtime : float;
  dir : bool;
  mode : int;
}

type t = {
  out : string -> unit;
  mutable pos : int;
  mutable entries : entry list;
}

let create out = { out; pos = 0; entries = [] }

let emit t s =
  t.out s;
  t.pos <- t.pos + String.length s

let le16 b v = Buffer.add_uint16_le b (v land 0xffff)
let le32 b v = Buffer.add_int32_le b v
let le32i b v = Buffer.add_int32_le b (Int32.of_int v)
let le64 b v = Buffer.add_int64_le b (Int64.of_int v)

let dos_time mtime =
  let tm = Unix.localtime mtime in
  if tm.tm_year + 1900 < 1980 then (0, 0x21)
  else
    ( (tm.tm_hour lsl 11) lor (tm.tm_min lsl 5) lor (tm.tm_sec / 2),
      ((tm.tm_year + 1900 - 1980) lsl 9)
      lor ((tm.tm_mon + 1) lsl 5)
      lor tm.tm_mday )

let header t ~name ~mtime =
  let b = Buffer.create 64 in
  let time, date = dos_time mtime in
  le32 b 0x04034b50l;
  le16 b 45;
  le16 b 0x0808;
  le16 b 0;
  le16 b time;
  le16 b date;
  le32 b 0l;
  le32 b 0l;
  le32 b 0l;
  le16 b (String.length name);
  le16 b 20;
  Buffer.add_string b name;
  le16 b 1;
  le16 b 16;
  le64 b 0;
  le64 b 0;
  emit t (Buffer.contents b)

let descriptor t crc size =
  let b = Buffer.create 24 in
  le32 b 0x08074b50l;
  le32 b crc;
  le64 b size;
  le64 b size;
  emit t (Buffer.contents b)

let add_dir ?(mode = 0o755) t ~name ~mtime =
  let name = if String.ends_with ~suffix:"/" name then name else name ^ "/" in
  let offset = t.pos in
  header t ~name ~mtime;
  descriptor t 0l 0;
  t.entries <-
    { name; crc = 0l; size = 0; offset; mtime; dir = true; mode } :: t.entries

(* [body] is handed a feed function and calls it with successive pieces. *)
let add_file ?(mode = 0o644) t ~name ~mtime body =
  let offset = t.pos in
  header t ~name ~mtime;
  let crc = ref 0l and size = ref 0 in
  body (fun s ->
      crc := crc_update !crc s 0 (String.length s);
      size := !size + String.length s;
      emit t s);
  descriptor t !crc !size;
  t.entries <-
    { name; crc = !crc; size = !size; offset; mtime; dir = false; mode }
    :: t.entries

let finish t =
  let cd_start = t.pos in
  let entries = List.rev t.entries in
  List.iter
    (fun e ->
      let b = Buffer.create 128 in
      let big = e.size >= 0xFFFFFFFF || e.offset >= 0xFFFFFFFF in
      let time, date = dos_time e.mtime in
      le32 b 0x02014b50l;
      le16 b ((3 lsl 8) lor 45);
      le16 b 45;
      le16 b 0x0808;
      le16 b 0;
      le16 b time;
      le16 b date;
      le32 b e.crc;
      if big then (
        le32 b 0xFFFFFFFFl;
        le32 b 0xFFFFFFFFl)
      else (
        le32i b e.size;
        le32i b e.size);
      le16 b (String.length e.name);
      le16 b (if big then 28 else 0);
      le16 b 0;
      le16 b 0;
      le16 b 0;
      if e.dir then
        le32 b
          (Int32.logor
             (Int32.shift_left (Int32.of_int (0o040000 lor e.mode)) 16)
             0x10l)
      else le32 b (Int32.shift_left (Int32.of_int (0o100000 lor e.mode)) 16);
      if big then le32 b 0xFFFFFFFFl else le32i b e.offset;
      Buffer.add_string b e.name;
      if big then (
        le16 b 1;
        le16 b 24;
        le64 b e.size;
        le64 b e.size;
        le64 b e.offset);
      emit t (Buffer.contents b))
    entries;
  let cd_size = t.pos - cd_start in
  let n = List.length entries in
  let eocd64 = t.pos in
  let b = Buffer.create 128 in
  le32 b 0x06064b50l;
  le64 b 44;
  le16 b ((3 lsl 8) lor 45);
  le16 b 45;
  le32 b 0l;
  le32 b 0l;
  le64 b n;
  le64 b n;
  le64 b cd_size;
  le64 b cd_start;
  le32 b 0x07064b50l;
  le32 b 0l;
  le64 b eocd64;
  le32 b 1l;
  le32 b 0x06054b50l;
  le16 b 0;
  le16 b 0;
  le16 b (min n 0xFFFF);
  le16 b (min n 0xFFFF);
  le32i b (min cd_size 0xFFFFFFFF);
  le32i b (min cd_start 0xFFFFFFFF);
  le16 b 0;
  emit t (Buffer.contents b)
