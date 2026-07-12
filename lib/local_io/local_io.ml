open Lwt.Syntax

type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let rw op lp flags buf ~offset =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then Lwt.return 0
  else
    let* fd = Lwt_unix_retry.openfile lp flags 0o644 in
    Lwt.finalize
      (fun () ->
        let* _ = Lwt_unix_retry.LargeFile.lseek fd offset Unix.SEEK_SET in
        let rec loop pos =
          if pos >= size then Lwt.return pos
          else
            let* n = op fd buf pos (size - pos) in
            if n = 0 then Lwt.return pos else loop (pos + n)
        in
        loop 0)
      (fun () -> Lwt_unix_retry.close fd)

let read lp buf ~offset = rw Lwt_bytes.read lp [Unix.O_RDONLY] buf ~offset

let write lp buf ~offset =
  rw Lwt_bytes.write lp [Unix.O_RDWR; Unix.O_CREAT] buf ~offset

(* Lwt_unix's positioned read/write only operate on [bytes], not the Bigarray
   buffer callers hand us, so each call pays one copy between the two —
   cheap next to the open/seek/close syscalls this is used to avoid.

   Run under [Async_none]: this fd is always one of our own cache files
   (see [Fd_cache]), read back moments after we wrote it or written right
   before it's hashed and uploaded, so it's essentially always still
   page-cache-resident. Async_none runs the pread/pwrite directly on the
   calling thread instead of dispatching it to Lwt's worker-thread pool
   (see [Lwt_unix.run_job]) — for a warm-cache hit that's strictly less
   work: no thread wake, no pool mutex, no context switch. The trade is
   that a genuine cache miss would briefly stall the whole Lwt event loop
   instead of just this fiber; scope this call as narrowly as the actual
   guarantee (our own recently-touched cache files) rather than using it
   for file I/O in general. *)
let prw op fd (buf : buffer) ~offset ~fill ~drain =
  let size = Bigarray.Array1.dim buf in
  if size = 0 then Lwt.return 0
  else
    Lwt_unix.with_async_none (fun () ->
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
        Lwt.return n)

let pread fd buf ~offset =
  prw Lwt_unix_retry.pread fd buf ~offset
    ~fill:(fun _ _ _ -> ())
    ~drain:(fun tmp buf n ->
      if n > 0 then Lwt_bytes.blit_from_bytes tmp 0 buf 0 n)

let pwrite fd buf ~offset =
  prw Lwt_unix_retry.pwrite fd buf ~offset
    ~fill:(fun tmp buf size -> Lwt_bytes.blit_to_bytes buf 0 tmp 0 size)
    ~drain:(fun _ _ _ -> ())
