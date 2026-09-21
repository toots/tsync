(* Whether a local store flushes an object before publishing its name.

   What is observed is the order of syscalls, since a crash is not something a
   test can stage: each temp file renamed or linked into place must have been
   fsynced first. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "durable-writes"
let flushed = ref []
let published = ref []

module Recording_syscalls = struct
  include Io_lwt.Syscalls

  let opened = ref []

  let openfile path flags perm =
    let+ fd = openfile path flags perm in
    opened := (fd, path) :: !opened;
    fd

  let fsync fd =
    let+ () = fsync fd in
    match List.find_opt (fun (opened_fd, _) -> opened_fd == fd) !opened with
      | Some (_, path) -> flushed := path :: !flushed
      | None -> ()

  let publish src = published := (src, List.mem src !flushed) :: !published

  let rename src dst =
    publish src;
    rename src dst

  let link src dst =
    publish src;
    link src dst
end

module Local =
  Local_backend.Over (Io_lwt.Core) (Io_lwt.Fs) (Recording_syscalls)
    (Io_lwt.Bounded)
    (Io_lwt.Clock)
    (Watch_lwt)

module B = (val Local.make ~verify_writes:false ~root ())

(* A count as well as the verdict: a store that stopped publishing through
   rename or link would leave nothing unflushed and pass on an empty list. *)
let all_flushed () =
  let publishes = List.rev !published in
  published := [];
  (List.length publishes, List.for_all snd publishes)

let data = Bigstring.of_string "body"

let () =
  Lwt_main.run
    (case "a put flushes its temp file before renaming it into place";
     let* () =
       B.put ~key:(Stored_key.listed "tsync/d/chunks/abc/abcd") ~data ()
     in
     let publishes, ok = all_flushed () in
     check "one object published" (publishes = 1);
     check "flushed before it was renamed" ok;

     case "a put_if_absent flushes its temp file before linking it into place";
     let* _ =
       B.put_if_absent ~key:(Stored_key.listed "tsync/d/claim") ~data ()
     in
     let publishes, ok = all_flushed () in
     check "one object published" (publishes = 1);
     check "flushed before it was linked" ok;
     Lwt.return_unit);
  Scratch.cleanup root
