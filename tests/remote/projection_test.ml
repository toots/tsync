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

(* 09 "Projection in parallel": one entry applied with [width] writes in
   flight, its slots read one by one or together; the records and versions it
   leaves, and the slots it read. *)
let parallel ~width ~together =
  let root = Filename.concat root (Printf.sprintf "%d-%b" width together) in
  let d = Domain_name.v "photos" in
  let inner = Local.create ~name:"main" (Filename.concat root "store") in
  let read = ref [] and reading = Mutex.create () in
  let note keys = Mutex.protect reading (fun () -> read := keys @ !read) in
  let main =
    {
      inner with
      get_opt =
        (fun k ->
          note [k];
          inner.get_opt k);
      get_many =
        (if together then
           Some
             (fun keys ->
               note keys;
               List.map inner.get_opt keys)
         else None);
    }
  in
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
  let at parent name = { Algebra.parent; name } in
  let top = at Folder_id.root in
  let upload content =
    Log_entry.Known
      (R.upload_chunks ~name:"f" ~size:(String.length content) ~chunk_size:8
         ~mtime:1. (fun _ -> Bytes (Bigstring.of_string content)))
  in
  let a = id 1 and b = id 2 and c = id 3 in
  let kept = upload "kept" and gone = upload "gone" in
  let edited = upload "edited" and fresh = upload "fresh" in
  P.apply ~before_write:ignore
    [
      `Folder (a, None, Some (top "a"));
      `Folder (b, None, Some (top "b"));
      `Folder (c, None, Some (top "c"));
      `File (at a "keep", None, Some kept);
      `File (at a "gone", None, Some gone);
    ];
  Mutex.protect reading (fun () -> read := []);
  P.apply ~width ~before_write:ignore
    [
      `File (at a "new", None, Some fresh);
      `File (at a "gone", Some gone, None);
      `File (at a "keep", Some kept, Some edited);
      `Folder (c, Some (top "c"), Some (at a "c"));
      `Folder (a, Some (top "a"), Some (top "b"));
      `Folder (b, Some (top "b"), Some (top "a"));
    ];
  let slots = Mutex.protect reading (fun () -> !read) in
  let records =
    P.fold
      (fun acc -> function
        | `File ((pl : Algebra.place), (m : Manifest.t)) ->
            Printf.sprintf "%s/%s=%d"
              (Folder_id.to_string pl.parent)
              pl.name m.size
            :: acc
        | `Folder (i, (pl : Algebra.place)) ->
            Printf.sprintf "%s/%s is %s"
              (if Folder_id.is_root pl.parent then ""
               else Folder_id.to_string pl.parent)
              pl.name (Folder_id.to_string i)
            :: acc)
      []
  in
  let versions =
    List.fold_left (fun n (_, l) -> n + List.length l) 0 (R.all_versions ())
  in
  Printf.sprintf
    "%s; versions kept: %d; slots read: %d, each once: %b, the new file's: %b"
    (String.concat ", " (List.sort compare records))
    versions (List.length slots)
    (List.length (List.sort_uniq compare slots) = List.length slots)
    (List.mem (Key.child d a "new") slots)

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let one_by_one = parallel ~width:1 ~together:false in
      p
        "== one entry of every kind, one write in flight, slots read one by one\n";
      p "  %s\n" one_by_one;
      List.iter
        (fun (width, together) ->
          p "  %d in flight, slots read together %b: the same %b\n" width
            together
            (parallel ~width ~together = one_by_one))
        [
          (1, true);
          (Projection.project_width, false);
          (Projection.project_width, true);
        ];
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
      let writes = Atomic.make 0 in
      let apply commands =
        Atomic.set writes 0;
        P.apply ~before_write:(fun () -> Atomic.incr writes) commands;
        Atomic.get writes
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
