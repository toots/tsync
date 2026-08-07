(* Streaming ZIP64 writer, STORED only. See zip_stream.mli for the contract.

   Member sizes are unknown when their header is written, so every archive is
   ZIP64 and every member carries a trailing data descriptor: a few bytes per
   member, in exchange for no size limit and no seeking. *)

let u16 b n =
  Buffer.add_char b (Char.chr (n land 0xff));
  Buffer.add_char b (Char.chr ((n lsr 8) land 0xff))

let u32 b n =
  let s = Bytes.create 4 in
  Bytes.set_int32_le s 0 n;
  Buffer.add_bytes b s

let u64 b n =
  let s = Bytes.create 8 in
  Bytes.set_int64_le s 0 n;
  Buffer.add_bytes b s

let u32i b n = u32 b (Int32.of_int n)

(* 0xFFFFFFFF in a 32-bit field means "read the real value from the ZIP64
   extra". *)
let max32 = 0xFFFFFFFFL
let sentinel32 = 0xFFFFFFFFl
let needs64 n = Int64.unsigned_compare n max32 >= 0

let crc_table =
  lazy
    (Array.init 256 (fun n ->
         let c = ref (Int32.of_int n) in
         for _ = 0 to 7 do
           c :=
             if Int32.logand !c 1l <> 0l then
               Int32.logxor 0xEDB88320l (Int32.shift_right_logical !c 1)
             else Int32.shift_right_logical !c 1
         done;
         !c))

let crc_init = 0xFFFFFFFFl

(* [running] is the pre-final value; {!crc_final} inverts it. *)
let crc_feed running s =
  let t = Lazy.force crc_table in
  let c = ref running in
  String.iter
    (fun ch ->
      let i =
        Int32.to_int
          (Int32.logand (Int32.logxor !c (Int32.of_int (Char.code ch))) 0xffl)
      in
      c := Int32.logxor t.(i) (Int32.shift_right_logical !c 8))
    s;
  !c

let crc_final running = Int32.lognot running

(* MS-DOS packed date/time; the format cannot represent anything before 1980, so
   older mtimes clamp to 1980-01-01. *)
let dos_time mtime =
  match Unix.localtime mtime with
    | tm when tm.Unix.tm_year + 1900 >= 1980 ->
        let time =
          (tm.Unix.tm_hour lsl 11) lor (tm.Unix.tm_min lsl 5)
          lor (tm.Unix.tm_sec / 2)
        in
        let date =
          ((tm.Unix.tm_year + 1900 - 1980) lsl 9)
          lor ((tm.Unix.tm_mon + 1) lsl 5)
          lor tm.Unix.tm_mday
        in
        (time, date)
    | _ | (exception _) -> (0, 0x21)

type member = {
  name : string;
  time : int;
  date : int;
  mode : int;
  is_dir : bool;
  crc : int32;
  size : int64;
  offset : int64;  (** local header offset, for the central directory *)
}

type cur = {
  c_name : string;
  c_time : int;
  c_date : int;
  c_mode : int;
  c_offset : int64;
  mutable c_crc : int32;
  mutable c_size : int64;
}

type t = {
  mutable pos : int64;  (** bytes emitted so far *)
  mutable members : member list;  (** reverse order *)
  mutable cur : cur option;
}

let create () = { pos = 0L; members = []; cur = None }

(* Everything emitted goes through here, so [pos] stays the true output offset
   the central directory's member offsets depend on. *)
let emit t b =
  let s = Buffer.contents b in
  t.pos <- Int64.add t.pos (Int64.of_int (String.length s));
  s

let flags = 0x0808 (* bit 3: data descriptor; bit 11: UTF-8 name *)
let version = 45 (* 4.5 = ZIP64 *)

let local_header t ~name ~time ~date =
  let b = Buffer.create (30 + String.length name + 20) in
  u32 b 0x04034b50l;
  u16 b version;
  u16 b flags;
  u16 b 0 (* stored *);
  u16 b time;
  u16 b date;
  u32i b 0 (* crc: in the data descriptor *);
  u32i b 0 (* compressed size: idem *);
  u32i b 0 (* uncompressed size: idem *);
  u16 b (String.length name);
  u16 b 20 (* ZIP64 extra below; its presence makes the descriptor 64-bit *);
  Buffer.add_string b name;
  u16 b 0x0001;
  u16 b 16;
  u64 b 0L;
  u64 b 0L;
  emit t b

let start_entry t ~name ~mtime ?(mode = 0o644) () =
  let time, date = dos_time mtime in
  t.cur <-
    Some
      {
        c_name = name;
        c_time = time;
        c_date = date;
        c_mode = mode;
        c_offset = t.pos;
        c_crc = crc_init;
        c_size = 0L;
      };
  local_header t ~name ~time ~date

let feed t block =
  match t.cur with
    | None -> invalid_arg "Zip_stream.feed: no member started"
    | Some c ->
        let n = Int64.of_int (String.length block) in
        c.c_crc <- crc_feed c.c_crc block;
        c.c_size <- Int64.add c.c_size n;
        (* The caller writes [block] itself, but it still moves the output
           offset the central directory is built from. *)
        t.pos <- Int64.add t.pos n

let close_member t ~crc ~size ~is_dir =
  match t.cur with
    | None -> invalid_arg "Zip_stream.end_entry: no member started"
    | Some c ->
        t.members <-
          {
            name = c.c_name;
            time = c.c_time;
            date = c.c_date;
            mode = c.c_mode;
            is_dir;
            crc;
            size;
            offset = c.c_offset;
          }
          :: t.members;
        t.cur <- None

let end_entry t =
  match t.cur with
    | None -> invalid_arg "Zip_stream.end_entry: no member started"
    | Some c ->
        let crc = crc_final c.c_crc and size = c.c_size in
        close_member t ~crc ~size ~is_dir:false;
        let b = Buffer.create 24 in
        u32 b 0x08074b50l;
        u32 b crc;
        u64 b size (* compressed = uncompressed: stored *);
        u64 b size;
        emit t b

let add_directory t ~name ~mtime =
  let name = if String.ends_with ~suffix:"/" name then name else name ^ "/" in
  let header = start_entry t ~name ~mtime ~mode:0o755 () in
  let descriptor = end_entry t in
  (* Re-tag as a directory: [end_entry] recorded it as a regular member. *)
  (match t.members with
    | m :: rest -> t.members <- { m with is_dir = true } :: rest
    | [] -> ());
  header ^ descriptor

(* External attributes: Unix mode in the high half, MS-DOS directory bit in the
   low half so DOS-heritage tools still see directories as such. *)
let external_attrs m =
  let unix_mode =
    if m.is_dir then 0o040000 lor m.mode else 0o100000 lor m.mode
  in
  Int32.logor
    (Int32.shift_left (Int32.of_int unix_mode) 16)
    (if m.is_dir then 0x10l else 0l)

let central_entry b m =
  (* If any of size/offset overflows 32 bits, all three move to the ZIP64 extra
     together: a partial extra is legal but trips implementations assuming a fixed
     field order. *)
  let big = needs64 m.size || needs64 m.offset in
  u32 b 0x02014b50l;
  u16 b ((3 lsl 8) lor version) (* made by: Unix *);
  u16 b version;
  u16 b flags;
  u16 b 0;
  u16 b m.time;
  u16 b m.date;
  u32 b m.crc;
  if big then (
    u32 b sentinel32;
    u32 b sentinel32)
  else (
    u32 b (Int64.to_int32 m.size);
    u32 b (Int64.to_int32 m.size));
  u16 b (String.length m.name);
  u16 b (if big then 28 else 0);
  u16 b 0 (* comment *);
  u16 b 0 (* disk *);
  u16 b 0 (* internal attrs *);
  u32 b (external_attrs m);
  if big then u32 b sentinel32 else u32 b (Int64.to_int32 m.offset);
  Buffer.add_string b m.name;
  if big then (
    u16 b 0x0001;
    u16 b 24;
    u64 b m.size (* uncompressed *);
    u64 b m.size (* compressed *);
    u64 b m.offset)

let finish t =
  if t.cur <> None then invalid_arg "Zip_stream.finish: member still open";
  let members = List.rev t.members in
  let cd_offset = t.pos in
  let b = Buffer.create (64 * List.length members) in
  List.iter (central_entry b) members;
  let cd_size = Int64.of_int (Buffer.length b) in
  let n = List.length members in
  (* ZIP64 end of central directory *)
  u32 b 0x06064b50l;
  u64 b 44L (* size of this record after this field *);
  u16 b ((3 lsl 8) lor version);
  u16 b version;
  u32i b 0 (* this disk *);
  u32i b 0 (* disk with CD start *);
  u64 b (Int64.of_int n);
  u64 b (Int64.of_int n);
  u64 b cd_size;
  u64 b cd_offset;
  (* ZIP64 locator *)
  u32 b 0x07064b50l;
  u32i b 0;
  u64 b (Int64.add cd_offset cd_size);
  u32i b 1 (* total disks *);
  (* End of central directory, sentinelled where ZIP64 takes over *)
  u32 b 0x06054b50l;
  u16 b 0;
  u16 b 0;
  u16 b (min n 0xFFFF);
  u16 b (min n 0xFFFF);
  if needs64 cd_size then u32 b sentinel32 else u32 b (Int64.to_int32 cd_size);
  if needs64 cd_offset then u32 b sentinel32
  else u32 b (Int64.to_int32 cd_offset);
  u16 b 0 (* comment *);
  emit t b
