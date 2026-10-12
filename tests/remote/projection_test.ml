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

let d = Domain_name.v "photos"

(* A client of [main], keeping versions. *)
let context root (main : Store.t) : (module Context.S) =
  let knowledge =
    { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
  in
  let composite =
    Composite.create ~domain:d
      ~data_dir:(Filename.concat root "data")
      ~owner:true ~poke:ignore ~knowledge
      [{ name = "main"; role = Main; store = main }]
  in
  (module struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = Some 8
    let max_downloads = 8
    let max_chunk_buffers = 4
  end)

(* 09 "Version not saved" and "Projector killed": a projection removing one
   file and replacing another while the write of a version fails, then while
   the delete that follows a saved version does. *)
let version_not_saved () =
  let root = Filename.concat root "versions" in
  let inner = Local.create ~name:"main" (Filename.concat root "store") in
  let versions = ref `Saved and passed = ref 0 and deletes = ref `Done in
  let main =
    {
      inner with
      put =
        (fun ?mode k b ->
          if Key.under (Key.versions d) k then (
            match !versions with
              | `Saved -> ()
              | `Link -> Fail.raise_ Fail.Link "the link is down"
              | `Missing ->
                  incr passed;
                  Fail.raise_ (Fail.Missing_chunks ["c"]) "chunks missing");
          inner.put ?mode k b);
      delete =
        (fun k ->
          if !deletes = `Link then Fail.raise_ Fail.Link "the link is down";
          inner.delete k);
    }
  in
  let module C = (val context root main) in
  let module R = Remote.Make (C) in
  let module P = Projection.Make (C) in
  let at name = { Algebra.parent = Folder_id.root; name } in
  let upload content =
    Log_entry.Known
      (R.upload_chunks ~name:"f" ~size:(String.length content) ~chunk_size:8
         ~mtime:1. (fun _ -> Bytes (Bigstring.of_string content)))
  in
  let old = upload "old" and edited = upload "edited" in
  let state () =
    let files =
      P.fold
        (fun acc -> function
          | `File ((pl : Algebra.place), (m : Manifest.t)) ->
              Printf.sprintf "%s=%d" pl.name m.size :: acc
          | `Folder _ -> acc)
        []
    in
    Printf.sprintf "%s; versions kept: %d"
      (String.concat ", " (List.sort compare files))
      (List.fold_left (fun n (_, l) -> n + List.length l) 0 (R.all_versions ()))
  in
  let project what entry =
    let result =
      match P.apply ~before_write:ignore entry with
        | () -> "projected"
        | exception Fail.E f -> "failed, " ^ Fail.kind_name f.kind
    in
    p "  %s: %s; %s\n" what result (state ())
  in
  let both gone kept : Log_entry.command list =
    [`File (at gone, Some old, None); `File (at kept, Some old, Some edited)]
  in
  P.apply ~before_write:ignore
    (List.map
       (fun name -> `File (at name, None, Some old))
       ["gone"; "kept"; "gone2"; "kept2"; "gone3"]);
  p "== a version that cannot be saved\n";
  p "  before: %s\n" (state ());
  versions := `Link;
  project "the link down" (both "gone" "kept");
  versions := `Saved;
  project "applied again, the link up" (both "gone" "kept");
  versions := `Missing;
  project "the main lacks the chunks" (both "gone2" "kept2");
  p "  versions the main refused and the projection passed: %d\n" !passed;
  versions := `Saved;
  deletes := `Link;
  let removal : Log_entry.command list = [`File (at "gone3", Some old, None)] in
  project "a version saved, its delete failing" removal;
  deletes := `Done;
  project "applied again" removal;
  let bodies =
    List.map
      (fun (_, e) -> R.get_version e)
      (R.list_versions Folder_id.root "gone3")
  in
  p "  that file's versions: %d, of one body: %b\n" (List.length bodies)
    (List.length (List.sort_uniq compare bodies) = 1)

(* 09 "Projection in parallel": one entry applied with [width] writes in
   flight, its slots read one by one or together; the records and versions it
   leaves, and the slots it read. *)
let parallel ~width ~together =
  let root = Filename.concat root (Printf.sprintf "%d-%b" width together) in
  let inner = Local.create ~name:"main" (Filename.concat root "store") in
  let read = ref [] and reading = Mutex.create () in
  let note keys = Mutex.protect reading (fun () -> read := keys @ !read) in
  (* A write takes long enough for the others of its pass to start. *)
  let in_flight = Atomic.make 0 and peak = Atomic.make 0 in
  let writing f =
    let now = Atomic.fetch_and_add in_flight 1 + 1 in
    if now > Atomic.get peak then Atomic.set peak now;
    Fun.protect
      ~finally:(fun () -> Atomic.decr in_flight)
      (fun () ->
        Rt.sleep 0.005;
        f ())
  in
  let main =
    {
      inner with
      put = (fun ?mode k b -> writing (fun () -> inner.put ?mode k b));
      delete = (fun k -> writing (fun () -> inner.delete k));
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
  let module C = (val context root main) in
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
  Atomic.set peak 0;
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
  let peak = Atomic.get peak in
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
  ( Printf.sprintf
      "%s; versions kept: %d; slots read: %d, each once: %b, the new file's: %b"
      (String.concat ", " (List.sort compare records))
      versions (List.length slots)
      (List.length (List.sort_uniq compare slots) = List.length slots)
      (List.mem (Key.child d a "new") slots),
    peak )

(* One write of a pass is refused: the writes issued, of the 40 it holds. *)
let refused () =
  let root = Filename.concat root "refused" in
  let inner = Local.create ~name:"main" (Filename.concat root "store") in
  let issued = Atomic.make 0 and refusing = ref false in
  let main =
    {
      inner with
      put =
        (fun ?mode k b ->
          if !refusing then (
            (* The first is refused at once; the others are still in flight
               when it is, so none of their fibers starts another. *)
            if Atomic.fetch_and_add issued 1 = 0 then
              Fail.raise_ Fail.Corrupt "refused";
            Rt.sleep 0.05);
          inner.put ?mode k b);
    }
  in
  let module C = (val context root main) in
  let module R = Remote.Make (C) in
  let module P = Projection.Make (C) in
  let content =
    Log_entry.Known
      (R.upload_chunks ~name:"f" ~size:4 ~chunk_size:8 ~mtime:1. (fun _ ->
           Bytes (Bigstring.of_string "body")))
  in
  refusing := true;
  let failed =
    match
      P.apply ~before_write:ignore
        (List.init 40 (fun i ->
             `File
               ( { Algebra.parent = Folder_id.root; name = string_of_int i },
                 None,
                 Some content )))
    with
      | () -> false
      | exception Fail.E _ -> true
  in
  Printf.sprintf "it fails %b, no more than %d writes were issued %b" failed
    Projection.project_width
    (Atomic.get issued <= Projection.project_width)

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let one_by_one, peak = parallel ~width:1 ~together:false in
      p
        "== one entry of every kind, one write in flight, slots read one by one\n";
      p "  %s\n" one_by_one;
      p "  writes in flight at most: %d\n" peak;
      List.iter
        (fun (width, together) ->
          let records, peak = parallel ~width ~together in
          p
            "  %d in flight, slots read together %b: the same %b, several \
             writes in flight %b\n"
            width together (records = one_by_one) (peak > 1))
        [
          (1, true);
          (Projection.project_width, false);
          (Projection.project_width, true);
        ];
      p "a refused write stops its pass: %s\n" (refused ());
      version_not_saved ();
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
