(* Times the cycles that publish a bulk rename: [N] files moved from one
   folder into another, against a local main. Usage: rename_push.exe N *)

open Tsync_core
open Tsync_store
open Tsync_sync

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let client root : (module Engine.S) =
  let data_dir = Filename.concat root "A/data" in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      [
        {
          Composite.name = "main";
          role = Main;
          store = Local.create ~name:"main" (Filename.concat root "store");
        };
      ]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = false
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat root "A/cache"
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = "A"
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 4
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
    let tuning () = Tuning.default
  end in
  (module Engine.Make (C))

let timed what f =
  let t = Unix.gettimeofday () in
  let v = f () in
  Printf.printf "%-28s %6.1f s\n%!" what (Unix.gettimeofday () -. t);
  v

let () =
  let n = int_of_string Sys.argv.(1) in
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-rename-push-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let (module E) = client root in
      E.start ~background:false ();
      E.mkdir "src" ~exclusive:false;
      E.mkdir "dst" ~exclusive:false;
      timed "create" (fun () ->
          for i = 1 to n do
            let path = Printf.sprintf "src/%05d.jpg" i in
            E.create path ~exclusive:false;
            E.write path ~off:0 (Bigstring.of_string (string_of_int i));
            E.close path
          done);
      timed "publish the files" (fun () ->
          E.drain ~grace:600. ();
          while E.pending_changes () > 0 do
            ignore (E.resync ())
          done);
      timed "rename" (fun () ->
          for i = 1 to n do
            let name = Printf.sprintf "%05d.jpg" i in
            E.rename ~src:("src/" ^ name) ~dst:("dst/" ^ name) ~exclusive:true
          done);
      Printf.printf "pending after the renames: %d\n%!" (E.pending_changes ());
      let committed =
        timed "publish the renames" (fun () ->
            let total = ref 0 in
            while E.pending_changes () > 0 do
              total := !total + (E.resync ()).committed
            done;
            !total)
      in
      Printf.printf "entries committed: %d\n%!" committed);
  Fs.rm_rf root
