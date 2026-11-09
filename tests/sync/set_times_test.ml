(* A frontend setting a file's times publishes a change of times alone, with
   the times given, a later creation time included (08 §3.3). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-set-times-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let client name : (module Engine.S) =
  let data_dir = Filename.concat root (name ^ "/data") in
  let store = Local.create ~name:"main" (Filename.concat root "store") in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      [{ name = "main"; role = Main; store }]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat root (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
    let projects_all = false
    let settings _ = (Tuning.default, symlinks)
  end in
  (module Engine.Make (C))

let times (module E : Engine.S) path = (E.stat path).times

let chunks () =
  let n = ref 0 in
  let rec walk dir =
    Array.iter
      (fun name ->
        let p = Filename.concat dir name in
        if Sys.is_directory p then walk p else incr n)
      (try Sys.readdir dir with Sys_error _ -> [||])
  in
  walk
    (List.fold_left Filename.concat root ["store"; "tsync"; "docs"; "chunks"]);
  !n

(* The puts of [path] the change feed holds after [cursor]. *)
let puts (module E : Engine.S) cursor path =
  match E.changes_since cursor ~limit:1000 with
    | `Stale -> -1
    | `Page (_, _, ops) ->
        List.length
          (List.filter
             (fun (o : Applied.op) ->
               match o.op with Op.Put { path = q; _ } -> q = path | _ -> false)
             ops)

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  Fs.mkdir_p (Filename.concat src "dir");
  Out_channel.with_open_bin (Filename.concat src "f.txt") (fun oc ->
      output_string oc "content");
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~background:false ();
      B.start ~background:false ();
      ignore (A.resync ());
      ignore (B.resync ());
      ignore (A.import src);
      A.drain ~grace:10. ();
      ignore (B.resync ());
      let held = times b "f.txt" in
      let objects = chunks () in
      let mtime = 1_015_218_367_123_456_789 in
      A.set_times "f.txt" ~mtime ();
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "a peer holds the mtime set: %b\n" ((times b "f.txt").mtime = mtime);
      p "the creation time is kept: %b\n"
        ((times b "f.txt").created = held.created);
      p "no chunk was written: %b\n" (objects > 0 && chunks () = objects);
      let created = held.created + 1_000_000_000 in
      A.set_times "f.txt" ~mtime ~created ();
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "a peer holds a later creation time set: %b\n"
        ((times b "f.txt").created = created);
      A.set_times "f.txt" ~mtime:(mtime + 500) ();
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "a time handed back within a microsecond changes nothing: %b\n"
        ((times b "f.txt").mtime = mtime);
      let opened = mtime + 1_000_000_000 in
      let cursor = A.cursor () in
      A.write "f.txt" ~off:0 (Bigstring.of_string "CONTENT");
      A.set_times "f.txt" ~mtime:opened ();
      p "times set on an open file are not fed before its close: %b\n"
        (puts a cursor "f.txt" = 0);
      A.close "f.txt";
      p "its close feeds it once: %b\n" (puts a cursor "f.txt" = 1);
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "times set on an open file reach a peer with its content: %b\n"
        ((times b "f.txt").mtime = opened
        && (B.stat "f.txt").size = String.length "CONTENT");
      (match A.set_times "dir" ~mtime () with
        | () -> p "a folder: accepted\n"
        | exception Fail.E { kind = Invalid; _ } -> p "a folder: invalid\n");
      p "pending: A %d, B %d\n" (A.activity ()).pending (B.activity ()).pending);
  Test_support.finish root
