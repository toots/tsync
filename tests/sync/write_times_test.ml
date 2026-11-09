(* write_whole's times (02 §2.6): a creation time a frontend passes goes
   through the 1980 floor, and the same bytes handed over again with other
   times update them even while the first handover is still staged. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-write-times-%d" (Unix.getpid ()))

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

let stat_times (module E : Engine.S) path = (E.stat path).times

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  Fs.mkdir_p src;
  let staging name body (times : Fs.times) =
    let path = Filename.concat src name in
    Out_channel.with_open_bin path (fun oc -> output_string oc body);
    Fs.set_times path times;
    path
  in
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~background:false ();
      B.start ~background:false ();
      ignore (A.resync ());
      ignore (B.resync ());
      let first = { Fs.mtime = 1_015_218_367_000_000_000; created = 0 } in
      ignore
        (A.write_whole ~created:0 "zero.txt" ~src:(staging "z" "zero" first)
           ~exclusive:false ());
      p "a creation time of 0 reads as the mtime: %b\n"
        ((stat_times a "zero.txt").created = first.mtime);
      ignore
        (A.write_whole "same.txt"
           ~src:(staging "s1" "same" first)
           ~exclusive:false ());
      let second =
        {
          Fs.mtime = 1_100_000_000_000_000_000;
          created = 900_000_000_000_000_000;
        }
      in
      ignore
        (A.write_whole ~created:second.created "same.txt"
           ~src:(staging "s2" "same" second)
           ~exclusive:false ());
      p "the same bytes again take the new times: %b\n"
        (stat_times a "same.txt" = second);
      A.drain ~grace:10. ();
      ignore (A.resync ());
      ignore (B.resync ());
      p "a peer holds them: %b\n" (stat_times b "same.txt" = second);
      p "pending: A %d, B %d\n" (A.activity ()).pending (B.activity ()).pending);
  Test_support.finish root
