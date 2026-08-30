(* How far ahead of a reader the prefetch reaches.

   A player lives on that distance: it reads a little at a time and stays fed
   only while whole cache chunks arrive before it gets there. If the window
   collapses onto the chunk being read, every crossing into the next one becomes
   a foreground fetch of the whole thing, and the reader waits for it.

   The shape is a phone's, and it is the shape that makes the window smallest:
   stored chunks well under a cache chunk, so a cache chunk is sixteen of them
   and is itself larger than [readahead_bytes] -- which pins the window to one
   group and leaves no slack to absorb an off-by-one.

   What is snapshotted is which chunks were asked for, not how long anything
   took: the distance is the claim, and a timing would only say how fast this
   machine is. *)

open Lwt.Syntax

let root = Scratch.dir "read_ahead"
let csize = 256 * 1024
let per = 16
let groups = 4
let chunks = per * groups
let size = chunks * csize
let read_size = 128 * 1024

let unused_store : (module Backend_lwt.Store) =
  (module Doubles.Down (struct
    let why = "no backend in this test"
  end))

module C : Conf_lwt.S = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/test/" "cursor"
  let shares_prefix = "tsync/shares/"
  let store = unused_store
  let members = []
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 8
  let chunk_size = Some csize
  let cache_chunk_size = Some (per * csize)
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false

  include Conf_lwt.Monad
end

let index_of_key k = int_of_string ("0x" ^ String.sub k 0 16)

(* Which stored chunks the store was asked for, and whether the ask was a range
   or the whole thing. *)
let asked : (int, unit) Hashtbl.t = Hashtbl.create 64
let whole : (int, unit) Hashtbl.t = Hashtbl.create 64

let body ~chunk_key ~offset ~length =
  let i = index_of_key chunk_key in
  let b = Bigstring.create length in
  for j = 0 to length - 1 do
    Bigstring.unsafe_set b j (Char.chr ((i + offset + j) land 0x7f))
  done;
  b

(* A link rather than a disk: a fetch that takes no time at all lets a prefetch
   finish before the read that would have waited for it, which is the one thing
   this must not assume. *)
module R = struct
  let chunk_size () = Lwt.return csize
  let fast_read = false
  let unused what = Lwt.fail (Failure ("read_ahead: " ^ what))

  let get_chunk ~chunk_key =
    Hashtbl.replace asked (index_of_key chunk_key) ();
    Hashtbl.replace whole (index_of_key chunk_key) ();
    let* () = Lwt_unix.sleep 0.002 in
    Lwt.return (body ~chunk_key ~offset:0 ~length:csize)

  let get_chunk_range ~chunk_key ~offset ~length =
    Hashtbl.replace asked (index_of_key chunk_key) ();
    let* () = Lwt_unix.sleep 0.002 in
    Lwt.return (body ~chunk_key ~offset ~length)

  let upload ~key:_ ~src_path:_ ~mtime:_ ~chunk_size:_ ?cancel:_ ?on_progress:_
      () =
    unused "upload"

  let upload_chunks ~key:_ ~size:_ ~chunk_size:_ ~mtime:_ ~source:_ ?cancel:_ ()
      =
    unused "upload_chunks"

  let fetch_manifest ~key:_ () = Lwt.return None
end

module D = Data_lwt.Make (C) (R)

let manifest =
  let keys = List.init chunks (fun i -> Printf.sprintf "%016x-%016x" i i) in
  Manifest.of_string
    (Manifest.encode ~name:"movie.bin" ~size:(Int64.of_int size)
       ~chunk_size:csize ~mtime:0. ~h1:(String.make 16 '0')
       ~h2:(String.make 16 '0') ~symlink:None ~keys)

(* The prefetch is fired and forgotten, so what it reached has to be waited for
   rather than observed the instant a read returns. *)
let settle () =
  let rec go n =
    if n = 0 then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.05 in
      go (n - 1)
  in
  go 20

let per_group tbl =
  String.concat " "
    (List.init groups (fun g ->
         let n =
           List.length
             (List.filter
                (fun i -> Hashtbl.mem tbl ((g * per) + i))
                (List.init per Fun.id))
         in
         Printf.sprintf "g%d=%d/%d" g n per))

let () =
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout read_size in
  Lwt_main.run
    (let read_at offset =
       let+ (_ : int) =
         D.pread ~id:"movie" ~manifest buf ~offset:(Int64.of_int offset)
       in
       ()
     in
     print_endline "=== one read, before anything says the stream is sequential";
     let* () = read_at 0 in
     let* () = settle () in
     Printf.printf "  chunks asked for   %s\n" (per_group asked);

     print_endline "";
     print_endline "=== reading on, which is what says it";
     (* The second contiguous read is the signal: from here a player is being
        streamed, and the prefetch is what has to stay in front of it. *)
     let* () = read_at read_size in
     let* () = settle () in
     Printf.printf "  chunks asked for   %s\n" (per_group asked);
     Printf.printf "  taken whole        %s\n" (per_group whole);

     print_endline "";
     print_endline "=== still inside the first cache chunk";
     let* () = read_at (csize * 4) in
     let* () = settle () in
     Printf.printf "  chunks asked for   %s\n" (per_group asked);
     (* The group after the one being read has to be here before the reader
        arrives at it; without that, crossing into it is a foreground fetch of a
        whole cache chunk and the reader waits for the network. *)
     Printf.printf "  group ahead ready  %b\n"
       (List.for_all
          (fun i -> Hashtbl.mem whole (per + i))
          (List.init per Fun.id));
     Lwt.return_unit);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
