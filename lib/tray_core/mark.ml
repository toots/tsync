let side = 32
let samples = 4

(* The paths of assets/tray/tsync-idle-symbolic.svg, in its 24-unit box: the
   stem with its hooked foot, the crossbar, and the arrow head. *)
let inside x y =
  let stem = x >= 9. && x <= 11. && y <= 15. && y >= 14. -. x in
  let hook =
    x <= 13. && y >= 15.
    &&
    let d = Float.hypot (x -. 13.) (y -. 15.) in
    d >= 2. && d <= 4.
  in
  let foot = x >= 13. && x <= 15. && y >= 17. && y <= 19. in
  let bar = x >= 6. && x <= 14. && y >= 7. && y <= 9. in
  let head = x >= 15. && Float.abs (y -. 18.) <= (19.6 -. x) *. 2.6 /. 4.6 in
  stem || hook || foot || bar || head

let coverage px py =
  let unit = 24. /. float side /. float samples in
  let hits = ref 0 in
  for sy = 0 to samples - 1 do
    for sx = 0 to samples - 1 do
      let x = (float ((px * samples) + sx) +. 0.5) *. unit
      and y = (float ((py * samples) + sy) +. 0.5) *. unit in
      if inside x y then incr hits
    done
  done;
  !hits * 255 / (samples * samples)

let crc_table =
  Array.init 256 (fun n ->
      let c = ref (Int32.of_int n) in
      for _ = 1 to 8 do
        c :=
          if Int32.logand !c 1l <> 0l then
            Int32.logxor 0xEDB88320l (Int32.shift_right_logical !c 1)
          else Int32.shift_right_logical !c 1
      done;
      !c)

let crc32 s =
  let c = ref 0xFFFFFFFFl in
  String.iter
    (fun ch ->
      let i =
        Int32.to_int
          (Int32.logand (Int32.logxor !c (Int32.of_int (Char.code ch))) 0xFFl)
      in
      c := Int32.logxor crc_table.(i) (Int32.shift_right_logical !c 8))
    s;
  Int32.logxor !c 0xFFFFFFFFl

let adler32 s =
  let a = ref 1 and b = ref 0 in
  String.iter
    (fun ch ->
      a := (!a + Char.code ch) mod 65521;
      b := (!b + !a) mod 65521)
    s;
  Int32.of_int ((!b lsl 16) lor !a)

let be32 buf n = Buffer.add_int32_be buf n

let chunk buf kind data =
  be32 buf (Int32.of_int (String.length data));
  Buffer.add_string buf kind;
  Buffer.add_string buf data;
  be32 buf (crc32 (kind ^ data))

(* A zlib stream of one stored block: the image is small, and the tray links
   no compressor. *)
let stored data =
  let b = Buffer.create (String.length data + 11) in
  Buffer.add_string b "\x78\x01\x01";
  Buffer.add_uint16_le b (String.length data);
  Buffer.add_uint16_le b (String.length data lxor 0xFFFF);
  Buffer.add_string b data;
  be32 b (adler32 data);
  Buffer.contents b

let png ~r ~g ~b =
  let pixels = Buffer.create (side * ((side * 4) + 1)) in
  for y = 0 to side - 1 do
    Buffer.add_char pixels '\000';
    for x = 0 to side - 1 do
      List.iter (Buffer.add_uint8 pixels) [r; g; b; coverage x y]
    done
  done;
  let header = Buffer.create 13 in
  be32 header (Int32.of_int side);
  be32 header (Int32.of_int side);
  Buffer.add_string header "\008\006\000\000\000";
  let out = Buffer.create 4300 in
  Buffer.add_string out "\137PNG\r\n\026\n";
  chunk out "IHDR" (Buffer.contents header);
  chunk out "IDAT" (stored (Buffer.contents pixels));
  chunk out "IEND" "";
  Buffer.contents out

let glyph color =
  match Scanf.sscanf_opt color "#%2x%2x%2x%!" (fun r g b -> (r, g, b)) with
    | Some (r, g, b) when String.length color = 7 -> Some (png ~r ~g ~b)
    | _ -> None
