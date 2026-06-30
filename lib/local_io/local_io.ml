type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let read lp buf ~offset =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then 0
  else begin
    let fd = Unix.openfile lp [Unix.O_RDONLY] 0 in
    let file_size = (Unix.LargeFile.fstat fd).Unix.LargeFile.st_size in
    let available = Int64.to_int (Int64.sub file_size offset) in
    let n = max 0 (min size available) in
    if n > 0 then begin
      let mapped =
        Bigarray.array1_of_genarray
          (Unix.map_file fd ~pos:offset Bigarray.char Bigarray.c_layout false
             [| n |])
      in
      Bigarray.Array1.blit mapped (Bigarray.Array1.sub buf 0 n)
    end;
    Unix.close fd;
    n
  end

let write lp buf ~offset =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then 0
  else begin
    let fd = Unix.openfile lp [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
    let end_pos = Int64.add offset (Int64.of_int size) in
    let file_size = (Unix.LargeFile.fstat fd).Unix.LargeFile.st_size in
    if end_pos > file_size then Unix.LargeFile.ftruncate fd end_pos;
    let mapped =
      Bigarray.array1_of_genarray
        (Unix.map_file fd ~pos:offset Bigarray.char Bigarray.c_layout true
           [| size |])
    in
    Bigarray.Array1.blit buf mapped;
    Unix.close fd;
    size
  end
