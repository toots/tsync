(* How much of one read is in flight at once.

   A read is cut into a piece per stored chunk it touches, and the piece count
   is the caller's: [fetch_range] takes any length, so a range over a large file
   is hundreds of them. Each piece stats the body, writes a record beside it and
   allocates its slice before it ever waits for the network, so unbounded that
   work scales with the range rather than with the transfer.

   The fetch stub blocks until released, holding every started piece in that
   state. Nothing here reaches a store: the range function is supplied directly,
   so what bounds the count is the read's own pool and not the download budget
   underneath it. *)

open Lwt.Syntax

let root = Scratch.dir "read_fanout"
let csize = 8
let chunks = 200
let downloads = 2

(* What {!Data} allows itself per read, four to a download so the budget below
   stays fed. *)
let slots = 4 * downloads

let unused_store : (module Backend_lwt.Store) =
  (module Doubles.Down (struct
    let why = "no backend in this test"
  end))

module C =
  (val Fixture.conf ~domain:"test" ~client_name:"Test" ~max_uploads:2
         ~max_downloads:downloads
         ~socket_path:(Filename.concat root "s.sock")
         ~chunk_size:csize
           (* One group per stored chunk, which is the shape that fans out most. *)
         ~cache_chunk_size:csize ~store:unused_store ~members:[] ~root ()
      : Conf_lwt.S)

let gate, release = Lwt.wait ()
let started = ref 0

let body_of key =
  Bigstring.of_string
    (String.make csize (Char.chr (Hashtbl.hash key land 0x5f)))

(* Only the read path is exercised; a write reaching here is a test that stopped
   testing what it says it does. *)
module R = struct
  let chunk_size () = Lwt.return csize
  let unused what = Lwt.fail (Failure ("read_fanout: " ^ what))

  let get_chunk ~chunk_key =
    incr started;
    let+ () = gate in
    body_of chunk_key

  let get_verified_chunk ~chunk_key:_ = unused "get_verified_chunk"

  let get_chunk_range ~chunk_key ~offset ~length =
    incr started;
    let+ () = gate in
    let body = body_of chunk_key in
    Bigstring.sub body ~off:offset
      ~len:(max 0 (min length (Bigstring.length body - offset)))

  let upload ~key:_ ~src_path:_ ~mtime:_ ~chunk_size:_ ?cancel:_ ?on_progress:_
      () =
    unused "upload"

  let upload_chunks ~key:_ ~size:_ ~chunk_size:_ ~mtime:_ ~source:_ ?cancel:_ ()
      =
    unused "upload_chunks"

  let fetch_manifest ~key:_ () = Lwt.return None
  let fast_read = false
  let known_chunk_count () = 0
end

module D = Data_lwt.Make (C) (R)

let manifest =
  let keys =
    List.init chunks (fun i ->
        Printf.sprintf "%016x-%016x" i (i * 7 land 0xffffffff))
  in
  Manifest.of_string
    (Manifest.encode ~name:"f"
       ~size:(Int64.of_int (chunks * csize))
       ~chunk_size:csize ~mtime:0. ~h1:(String.make 16 '0')
       ~h2:(String.make 16 '0') ~symlink:None ~keys)

let yes b = if b then "yes" else "no"

let () =
  Lwt_main.run
    (let want = chunks * csize in
     let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout want in
     let reading = D.pread ~id:"f" ~manifest buf ~offset:0L in

     (* Real filesystem work happens on the blocking pool, so this waits rather
        than merely yielding. *)
     let rec settle n =
       if n = 0 then Lwt.return_unit
       else
         let* () = Lwt_unix.sleep 0.02 in
         settle (n - 1)
     in
     let* () = settle 25 in

     Printf.printf "=== one read over %d stored chunks\n" chunks;
     Printf.printf "  the fixture really is many pieces: %s\n"
       (yes (Manifest.count manifest = chunks));
     Printf.printf "  no more pieces start than there are slots: %s\n"
       (yes (!started <= slots));
     Printf.printf "  but the read is not serialised either: %s\n"
       (yes (!started > 1));

     Lwt.wakeup_later release ();
     let+ got = reading in
     Printf.printf "  and every byte still arrives: %s\n" (yes (got = want)));
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
