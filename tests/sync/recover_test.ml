open Tsync_core
open Tsync_store
open Tsync_checkout
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-recover-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"
let data_dir = Filename.concat root "data"
let cache_root = Filename.concat root "cache"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let engine () : (module Engine.S) =
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
    let cache_root = cache_root
    let data_dir = data_dir
    let client_uuid = Identity.client_uuid data_dir
    let client_name = "a"
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  (module Engine.Make (C))

let () =
  Rt.run_sync (fun () ->
      let staged = Staged.create ~cache_root d in
      let bodies =
        let (module E) = engine () in
        E.start ~poll_journal:false ();
        E.set_paused true;
        E.create "f.txt" ~exclusive:false;
        E.write "f.txt" ~off:0 (Bigstring.of_string "unpublished bytes");
        E.close "f.txt";
        Staged.bodies_named (Option.get (Staged.edit staged "f.txt"))
      in
      p "staged bodies: %d\n" (List.length bodies);
      let manifest = Staged.manifest_path staged "f.txt" in
      let encoded = Fs.read_file manifest in
      Fs.durable_replace manifest
        (String.sub encoded 0 (String.length encoded - 1));
      let (module E) = engine () in
      E.start ~poll_journal:false ();
      p "set aside: %b\n" (Fs.exists (manifest ^ ".bad"));
      List.iter
        (fun b -> p "body kept: %b\n" (Staged.body_size staged b >= 0))
        bodies);
  Fs.rm_rf root
