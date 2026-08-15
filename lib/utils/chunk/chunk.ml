open Lwt.Syntax

type t = Bigstringaf.t

let of_buffer buf = buf
let buffer t = t
let empty = Bigstringaf.empty
let create = Bigstringaf.create
let length = Bigstringaf.length
let of_string s = Bigstringaf.of_string s ~off:0 ~len:(String.length s)
let to_string = Bigstringaf.to_string
let hash_hex t seed = Xxhash.hash_bigstring_hex t seed

(* Synchronous because [mmap] moves no data: this costs an open and a close, and
   the reads happen later on the pages actually touched. *)
let map_file ~path ~offset ~len =
  if len = 0 then empty
  else (
    let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Bigarray.array1_of_genarray
          (Unix.map_file fd ~pos:(Int64.of_int offset) Bigarray.char
             Bigarray.c_layout false [| len |])))

(* An empty body still has to make the name appear, and a write that moves no
   bytes creates nothing. *)
let write_to ~path t ~offset =
  if length t = 0 then
    let* fd =
      Lwt_unix_retry.openfile path [Unix.O_WRONLY; Unix.O_CREAT] 0o644
    in
    Lwt_unix_retry.close fd
  else
    let+ (_ : int) = Local_io.write path t ~offset:(Int64.of_int offset) in
    ()
