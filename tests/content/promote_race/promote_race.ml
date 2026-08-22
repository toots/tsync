(* A read running while an upload publishes.

   Promotion swaps a file between two representations, staged bodies named by
   uuid and cache groups named by content, and a reader picks one by asking
   which the key resolves to -- so an ordering that unlinks either before the
   marker selecting it has moved hands the reader a path that is already gone. *)

open Lwt.Syntax

let root = "/tmp/tsync-promote-race-test"
let store_dir = root ^ "/store"
let cache_dir = root ^ "/cache"
let data_dir = root ^ "/data"

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "racedom"
  let domain_prefix = "tsync/racedom/manifests/"
  let chunk_prefix = "tsync/racedom/chunks/"
  let versions_prefix = "tsync/racedom/versions/"
  let journal_prefix = "tsync/racedom/journal/"
  let cursor_key = "tsync/racedom/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some store_dir) ()

  let members = [Backend.member ~name:"local" store]
  let cache_root = cache_dir
  let data_dir = data_dir
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 2
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module Mf = Checkout.Make (C)
module Mfs = Staged_manifest.Make (C)
module D = Data.Make (C) (R)

let key = C.domain_prefix ^ "file.txt"

(* Long enough that a promotion is several groups of work, so a reader has
   somewhere to land. *)
let body = String.concat "" (List.init 64 (fun i -> Printf.sprintf "%08d" i))

let buffer_of_string s =
  let buf =
    Bigarray.Array1.create Bigarray.char Bigarray.c_layout (String.length s)
  in
  String.iteri (fun i c -> Bigarray.Array1.set buf i c) s;
  buf

let string_of_buffer buf len =
  String.init len (fun i -> Bigarray.Array1.get buf i)

let write_all key s =
  let+ (_ : int) = D.write key (buffer_of_string s) ~offset:0L in
  ()

let read_all key =
  let want = String.length body in
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout want in
  let+ n = D.pread_key key buf ~offset:0L in
  (n, string_of_buffer buf n)

(* Recorded rather than raised, so one run reports every way it went wrong. *)
let failures = ref []
let note what = failures := what :: !failures

let report label =
  (match List.rev !failures with
    | [] -> Printf.printf "%s: ok\n" label
    | fs -> List.iter (Printf.printf "%s: %s\n" label) fs);
  failures := []

let reader_loop ~expect ~stop =
  let rec go n =
    if !stop then Lwt.return n
    else
      let* () =
        Lwt.catch
          (fun () ->
            let+ got, s = read_all key in
            if got <> String.length expect then
              note
                (Printf.sprintf "short read: %d of %d" got
                   (String.length expect))
            else if s <> expect then note "read returned the wrong bytes")
          (fun exn ->
            note (Printexc.to_string exn);
            Lwt.return_unit)
      in
      let* () = Lwt.pause () in
      go (n + 1)
  in
  go 0

(* A write arriving while a promotion runs must not reach the bytes that
   promotion is handing to the chunk store under their content name: the name
   was computed from what the upload hashed, so changing them afterwards
   publishes one file's content under another's key. Uniform fixtures make it
   visible -- every write lays down one letter, so a body holding both was
   assembled from two of them. *)
let write_during_promote round =
  let key = Printf.sprintf "%sraced-%d.txt" C.domain_prefix round in
  let size = 512 in
  let fill c = String.make size c in
  let* () = write_all key (fill 'A') in
  let* () = D.sync key () in
  let* () = write_all key (fill 'A') in

  let stop = ref false in
  let rec writer n =
    if !stop then Lwt.return n
    else
      let* () = write_all key (fill (if n land 1 = 0 then 'B' else 'A')) in
      let* () = Lwt.pause () in
      writer (n + 1)
  in
  let writing = writer 0 in
  let* () = D.sync key () in
  stop := true;
  let* writes = writing in
  (* Settle whatever the last write left owed. *)
  let* () = D.sync key () in

  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout size in
  let* n = D.pread_key key buf ~offset:0L in
  let s = string_of_buffer buf n in
  if n <> size then note (Printf.sprintf "short read after the race: %d" n)
  else if not (String.for_all (fun c -> c = s.[0]) s) then
    note
      (Printf.sprintf "torn body: %d A, %d B"
         (String.fold_left (fun n c -> if c = 'A' then n + 1 else n) 0 s)
         (String.fold_left (fun n c -> if c = 'B' then n + 1 else n) 0 s));
  Lwt.return writes

let main () =
  let* (_ : Unix.process_status) = Lwt_unix.system ("rm -rf " ^ root) in
  List.iter
    (fun d -> if not (Sys.file_exists d) then Unix.mkdir d 0o755)
    [root; store_dir; cache_dir; data_dir];

  (* Published first, so the sync being raced is a promotion rather than an
     initial upload. *)
  let* () = write_all key body in
  let* () = D.sync key () in

  (* Over the whole file, so every group is touched and local -- the condition
     promote_chunked requires before it will publish a group locally. *)
  let edited = String.map (fun c -> if c = '0' then 'x' else c) body in
  let* () = write_all key edited in

  (* Several at once: the window between resolving the key and reading what it
     named is narrow, and one reader in lockstep with the promotion mostly
     misses it. *)
  let stop = ref false in
  let readers =
    Lwt.all (List.init 8 (fun _ -> reader_loop ~expect:edited ~stop))
  in
  let* () = D.sync key () in
  stop := true;
  let* counts = readers in
  let reads = List.fold_left ( + ) 0 counts in

  (* A run that raced nothing would pass while testing nothing. *)
  if reads < 2 then
    note (Printf.sprintf "only %d reads raced the promote" reads);

  let* got, s = read_all key in
  if got <> String.length edited || s <> edited then
    note "the file is wrong after the promote";
  report "reads during a promotion";

  (* Repeated: a write only tears a group if it lands between the upload that
     hashed the bytes and the promotion that re-reads them, which is a slice of
     each sync rather than all of it. *)
  let rounds = 12 in
  let* writes = Lwt_list.map_s write_during_promote (List.init rounds Fun.id) in
  (* Counted over every round rather than within one: a write reaching the
     promotion itself waits for the lock, so how many turns a single round
     gives the writer is the machine's business, not this filesystem's. *)
  let total = List.fold_left ( + ) 0 writes in
  if total < rounds then
    note (Printf.sprintf "only %d writes across %d rounds" total rounds);
  report "writes during a promotion";
  Lwt.return_unit

let () = Lwt_main.run (main ())
