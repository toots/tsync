(* tree_gen STORE_ROOT DOMAIN FOLDERS FILES_PER_FOLDER: a local store holding
   that many folders and files, committed as log entries and projected, for
   rebuild_mem to arrive on. Files are symlinks, so no chunk is written. *)

open Tsync_core
open Tsync_store
open Tsync_remote

let () =
  let root = Sys.argv.(1)
  and d = Domain_name.v Sys.argv.(2)
  and folders = int_of_string Sys.argv.(3)
  and files = int_of_string Sys.argv.(4) in
  Rt.run_sync (fun () ->
      let store = Local.create ~name:"main" root in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root ".gen-data")
          ~owner:true ~poke:ignore
          ~knowledge:
            { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
          [{ name = "main"; role = Main; store }]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = false
        let chunk_size_config = None
        let max_downloads = 8
        let max_chunk_buffers = 4
      end in
      let module P = Projection.Make (C) in
      let log = Log_store.create d C.store in
      let n = ref (Log_store.tree_head log) in
      let commit commands =
        incr n;
        ignore
          (Log_store.create_entry log !n
             (Log_entry.encode { author = "gen"; commands }));
        P.apply ~before_write:ignore commands;
        Log_store.raise_tree_head log !n
      in
      for f = 1 to folders do
        let id = Folder_id.mint ~uuid:"bbbbbbbbbbbb" ~counter:f in
        let name = Printf.sprintf "folder-%05d" f in
        commit
          (`Folder (id, None, Some { Algebra.parent = Folder_id.root; name })
          :: List.init files (fun i ->
              let leaf = Printf.sprintf "file-%04d.txt" i in
              `File
                ( { Algebra.parent = id; name = leaf },
                  None,
                  Some
                    (Log_entry.Known
                       (Manifest.symlink ~name:leaf ~mtime:1. "target")) )))
      done;
      Printf.printf "%d entries, %d folders, %d files\n" !n folders
        (folders * files))
