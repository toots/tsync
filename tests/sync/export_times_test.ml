(* Export of a file already there (spec 05 §4.4): its bytes are left, its
   times are the manifest's, so a change of times alone reaches it. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-export-times-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let client name : (module Engine.S) * (module Tsync_remote.Context.S) =
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
  ((module Engine.Make (C)), (module C : Tsync_remote.Context.S))

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  Fs.mkdir_p src;
  let path = Filename.concat src "a.txt" in
  Out_channel.with_open_bin path (fun oc -> output_string oc "alpha");
  let times =
    { Fs.mtime = 1_015_218_367_123_456_700; created = 900_000_000_000_000_000 }
  in
  Fs.set_times path times;
  Rt.run_sync (fun () ->
      let (module A), ctx = client "A" in
      let module X = Export.Make ((val ctx)) in
      A.start ~background:false ();
      ignore (A.import src);
      A.drain ~grace:10. ();
      let cache_root = Filename.concat root "A/cache" in
      let dst = Filename.concat root "out" in
      let dest = Filename.concat dst "a.txt" in
      let export () =
        let r = X.export ~cache_root ~dst [""] in
        p "exported %d, already there %d\n" r.exported r.already_there
      in
      export ();
      (* Within the export's slack, so the file counts as already there. *)
      Fs.set_times dest { times with mtime = times.mtime + 1_000_000_000 };
      export ();
      p "its times are the manifest's again: %b\n"
        ((Fs.times dest).mtime = times.mtime));
  Test_support.finish root
