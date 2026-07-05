open Lwt.Syntax

type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let rw op lp flags buf ~offset =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then Lwt.return 0
  else
    let* fd = Lwt_unix.openfile lp flags 0o644 in
    Lwt.finalize
      (fun () ->
        let* _ = Lwt_unix.LargeFile.lseek fd offset Unix.SEEK_SET in
        let rec loop pos =
          if pos >= size then Lwt.return pos
          else
            let* n = op fd buf pos (size - pos) in
            if n = 0 then Lwt.return pos else loop (pos + n)
        in
        loop 0)
      (fun () -> Lwt_unix.close fd)

let read lp buf ~offset = rw Lwt_bytes.read lp [Unix.O_RDONLY] buf ~offset

let write lp buf ~offset =
  rw Lwt_bytes.write lp [Unix.O_RDWR; Unix.O_CREAT] buf ~offset

(* Lwt_unix's positioned read/write only operate on [bytes], not the Bigarray
   buffer callers hand us, so each call pays one copy between the two —
   cheap next to the open/seek/close syscalls this is used to avoid. *)
let prw op fd (buf : buffer) ~offset ~fill ~drain =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then Lwt.return 0
  else
    let tmp = Bytes.create size in
    fill tmp buf size;
    let base = Int64.to_int offset in
    let rec loop pos =
      if pos >= size then Lwt.return pos
      else
        let* n = op fd tmp ~file_offset:(base + pos) pos (size - pos) in
        if n = 0 then Lwt.return pos else loop (pos + n)
    in
    let* n = loop 0 in
    drain tmp buf n;
    Lwt.return n

let pread fd buf ~offset =
  prw Lwt_unix.pread fd buf ~offset
    ~fill:(fun _ _ _ -> ())
    ~drain:(fun tmp buf n -> if n > 0 then Lwt_bytes.blit_from_bytes tmp 0 buf 0 n)

let pwrite fd buf ~offset =
  prw Lwt_unix.pwrite fd buf ~offset
    ~fill:(fun tmp buf size -> Lwt_bytes.blit_to_bytes buf 0 tmp 0 size)
    ~drain:(fun _ _ _ -> ())
