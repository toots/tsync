(* Entries applied to a local store: the tree after each, applying twice, and
   the versions a projection saves. *)

open Tsync_core
open Tsync_store
open Tsync_remote

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-projection-%d" (Unix.getpid ()))

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let d = Domain_name.v "photos" in
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let knowledge =
        { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
      in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore ~knowledge
          [{ name = "main"; role = Main; store = main }]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = Some 8
        let max_downloads = 8
        let max_chunk_buffers = 4
      end in
      let module R = Remote.Make (C) in
      let module P = Projection.Make (C) in
      let id n = Folder_id.mint ~uuid:"aaaaaaaaaaaaaaaa" ~counter:n in
      let name_of i = "#" ^ Folder_id.to_string i in
      let place (pl : Algebra.place) =
        (if Folder_id.is_root pl.parent then "" else name_of pl.parent)
        ^ "/" ^ pl.name
      in
      let upload name content =
        Log_entry.Known
          (R.upload_chunks ~name ~size:(String.length content) ~chunk_size:8
             ~mtime:1. (fun i ->
               Bytes
                 (Bigstring.of_string
                    (String.sub content (i * 8)
                       (min 8 (String.length content - (i * 8)))))))
      in
      let writes = ref 0 in
      let apply commands =
        writes := 0;
        P.apply ~before_write:(fun () -> incr writes) commands;
        !writes
      in
      let show what =
        let lines =
          P.fold
            (fun acc -> function
              | `File (pl, (m : Manifest.t)) ->
                  Printf.sprintf "%s = %d bytes" (place pl) m.size :: acc
              | `Folder (i, pl) ->
                  Printf.sprintf "%s is %s" (place pl) (name_of i) :: acc)
            []
        in
        let versions =
          List.fold_left
            (fun n (_, l) -> n + List.length l)
            0 (R.all_versions ())
        in
        p "== %s\n" what;
        List.iter (p "  %s\n") (List.sort compare lines);
        p "  versions kept: %d\n" versions
      in
      let at parent name = { Algebra.parent; name } in
      let a = id 1 and b = id 2 in
      let one = upload "one" "first content" in
      let two = upload "one" "second content, longer" in
      let entry1 : Log_entry.command list =
        [
          `Folder (a, None, Some (at Folder_id.root "a"));
          `Folder (b, None, Some (at Folder_id.root "b"));
          `File (at a "one", None, Some one);
        ]
      in
      p "writes: %d\n" (apply entry1);
      show "two folders and a file";
      p "writes: %d\n" (apply entry1);
      show "the same entry applied again";
      let entry2 : Log_entry.command list =
        [`File (at a "one", Some one, Some two)]
      in
      ignore (apply entry2);
      ignore (apply entry2);
      show "the file edited, applied twice: one version";
      let entry3 : Log_entry.command list =
        [
          `Folder (a, Some (at Folder_id.root "a"), Some (at Folder_id.root "b"));
          `Folder (b, Some (at Folder_id.root "b"), Some (at Folder_id.root "a"));
        ]
      in
      ignore (apply entry3);
      show "the folders swap names: the file follows its folder";
      let entry4 : Log_entry.command list =
        [
          `File (at a "one", Some two, None);
          `File (at b "moved", None, Some two);
          `Folder (a, Some (at Folder_id.root "b"), None);
        ]
      in
      ignore (apply entry4);
      ignore (apply entry4);
      show "the file moved, its folder removed";
      let stopped =
        match
          P.apply
            ~before_write:(fun () -> Fail.raise_ Fail.Link "lease lost")
            [`File (at b "moved", Some two, None)]
        with
          | () -> false
          | exception Fail.E _ -> true
      in
      p "a projection whose lease check fails writes nothing: %b\n" stopped;
      show "unchanged";
      p "left under the removed folder: %d objects\n"
        (List.length (main.list_prefix (Key.namespace d a))));
  Fs.rm_rf root
