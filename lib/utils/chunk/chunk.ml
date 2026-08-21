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

(* Synchronous because [mmap] moves no data: the reads happen later, on the pages
   actually touched. *)
let map_fd fd ~offset ~len =
  if len = 0 then empty
  else
    Bigarray.array1_of_genarray
      (Unix.map_file fd ~pos:(Int64.of_int offset) Bigarray.char
         Bigarray.c_layout false [| len |])

(* Keyed by directory, because an import source and the cache need not be on the
   same filesystem, and remembered so one that cannot clone costs a single
   failed attempt rather than one per mapping. *)
let clonable : (string, bool) Hashtbl.t = Hashtbl.create 8
let warned_no_clone = ref false

let snapshot path =
  let dir = Filename.dirname path in
  if Hashtbl.find_opt clonable dir = Some false then None
  else (
    let fd = try Device.clone ~src:path with Unix.Unix_error _ -> None in
    Hashtbl.replace clonable dir (Option.is_some fd);
    if Option.is_none fd && not !warned_no_clone then (
      warned_no_clone := true;
      Log.warn
        "%s is on a filesystem that cannot clone: mappings there are of the \
         file itself, and read whatever it holds when the pages are touched"
        dir);
    fd)

let open_snapshot path =
  match snapshot path with
    | Some fd -> fd
    | None -> Unix.openfile path [Unix.O_RDONLY] 0

let map_file ~path ~offset ~len =
  if len = 0 then empty
  else (
    let fd = open_snapshot path in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () -> map_fd fd ~offset ~len))

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
