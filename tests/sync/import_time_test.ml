(* A re-import that finds a file's time changed and its bytes the same
   publishes the time (conflict-resolution §2). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-import-time-%d" (Unix.getpid ()))

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

let mtime (module E : Engine.S) name =
  match
    List.find_opt (fun (e : E.entry) -> e.name = name) (E.list_children "")
  with
    | Some e -> e.st.times.mtime
    | None -> -1

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  Fs.mkdir_p src;
  let path = Filename.concat src "old.txt" in
  Out_channel.with_open_bin path (fun oc -> output_string oc "old");
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
      let written = 1015218367_123456789 in
      Fs.set_times path { mtime = written; created = written };
      ignore (A.import ~force_rehash:true src);
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "A holds the new time: %b\n" (mtime a "old.txt" = written);
      p "B holds the new time: %b\n" (mtime b "old.txt" = written);
      p "pending: A %d, B %d\n" (A.activity ()).pending (B.activity ()).pending);
  Test_support.finish root
