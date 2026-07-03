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
