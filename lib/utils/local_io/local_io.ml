open Lwt.Syntax

type buffer = Bigstringaf.t

let rw op lp flags buf ~offset =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then Lwt.return 0
  else
    let* fd = Io_lwt.Retry.openfile lp flags 0o644 in
    Lwt.finalize
      (fun () ->
        let* _ = Io_lwt.Retry.LargeFile.lseek fd offset Unix.SEEK_SET in
        let rec loop pos =
          if pos >= size then Lwt.return pos
          else
            let* n = op fd buf pos (size - pos) in
            if n = 0 then Lwt.return pos else loop (pos + n)
        in
        loop 0)
      (fun () -> Io_lwt.Retry.close fd)

let zero buf ~pos ~len =
  Bigarray.Array1.fill (Bigarray.Array1.sub buf pos len) '\000'

let read lp buf ~offset = rw Lwt_bytes.read lp [Unix.O_RDONLY] buf ~offset

let write lp buf ~offset =
  rw Lwt_bytes.write lp [Unix.O_RDWR; Unix.O_CREAT] buf ~offset

external unix_pread : Unix.file_descr -> buffer -> int -> int -> int -> int
  = "caml_tsync_pread_bytecode" "caml_tsync_pread"

external unix_pwrite : Unix.file_descr -> buffer -> int -> int -> int -> int
  = "caml_tsync_pwrite_bytecode" "caml_tsync_pwrite"

let positioned op fd buf ~file_offset pos len =
  Lwt.return (op (Lwt_unix.unix_file_descr fd) buf file_offset pos len)

let pread fd buf ~file_offset pos len =
  positioned unix_pread fd buf ~file_offset pos len

let pwrite fd buf ~file_offset pos len =
  positioned unix_pwrite fd buf ~file_offset pos len
