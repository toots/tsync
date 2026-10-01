(* tsync mirror (spec 05 §4.6): a local main copied to a local replica, by
   scope, additively, chunks before manifests and the cursor last. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-mirror-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main = Local.create ~name:"main" (Filename.concat root "main")
  and inner = Local.create ~name:"copy" (Filename.concat root "copy") in
  let order = ref [] in
  let copy =
    {
      inner with
      put =
        (fun ?mode k b ->
          order := Key.to_string k :: !order;
          inner.put ?mode k b);
    }
  in
  let cs = Chunking.chunk_size_min in
  let chunk s = Chunk_key.of_body s in
  let put_chunk s = main.put (Key.chunk d (chunk s)) (Bigstring.of_string s) in
  let manifest name chunks =
    (Manifest.make ~name
       ~size:(List.length chunks * cs)
       ~mtime:0. ~chunk_size:cs (List.map chunk chunks))
      .body
  in
  let folder = Folder_id.v "0000000000a1-1" in
  let put k s = main.put k (Bigstring.of_string s) in
  Rt.run_sync (fun () ->
      List.iter put_chunk ["c1"; "c2"; "c3"];
      put (Key.child d Folder_id.root "a.txt") (manifest "a.txt" ["c1"]);
      put
        (Key.child d Folder_id.root "docs")
        (Folder.marker_body { name = "docs"; id = folder });
      put (Key.anchor d folder)
        (Folder.anchor_body { parent = Folder_id.root; aname = "docs" });
      put (Key.child d folder "b.txt") (manifest "b.txt" ["c2"; "c3"]);
      put (Key.index d Folder_id.root) "an index";
      put (Key.version d ~group:"0000000000a1-1/h" ~ns:1L) (manifest "v" ["c1"]);
      put (Key.journal_entry d ~month:"2026-10" ~entry:"e1") "[]";
      put (Key.cursor d) "e1";
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            {
              Composite.is_index = (fun _ -> false);
              is_journal = (fun _ -> false);
            }
          [
            { name = "main"; role = Main; store = main };
            { name = "copy"; role = Replica; store = copy };
          ]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = true
        let chunk_size_config = None
        let max_downloads = 1
        let max_chunk_buffers = 4
      end in
      let module M = Store_mirror.Make (C) in
      let run label ?source scope =
        order := [];
        match M.mirror ?source scope with
          | r ->
              List.iter
                (fun (c : Store_mirror.copied) ->
                  p
                    "%s: %s -> %s, %d checked, %d copied (%d bytes), %d refused\n"
                    label r.source c.name c.checked c.copied c.copied_bytes
                    (List.length c.failed))
                r.copies
          | exception Fail.E f -> p "%s: refused: %s\n" label f.reason
      in
      let kinds () =
        List.rev_map
          (fun k ->
            if String.contains k '/' && Key.chunk_of (Key.v k) <> None then
              "chunk"
            else if k = Key.to_string (Key.cursor d) then "cursor"
            else "other")
          !order
      in
      p "== everything\n";
      run "all" All;
      let ks = kinds () in
      let rec firsts seen = function
        | [] -> List.rev seen
        | k :: rest -> firsts (if List.mem k seen then seen else k :: seen) rest
      in
      p "order of kinds: %s\n" (String.concat ", " (firsts [] ks));
      p "index copied: %b\n"
        (inner.head_opt (Key.index d Folder_id.root) <> None);
      p "\n== again\n";
      run "all" All;
      p "\n== a changed manifest and a short chunk on the copy\n";
      put (Key.child d Folder_id.root "a.txt") (manifest "a.txt" ["c2"]);
      inner.put (Key.chunk d (chunk "c3")) (Bigstring.of_string "c");
      run "all" All;
      p "\n== manifests only\n";
      put_chunk "c9";
      put (Key.child d folder "new.txt") (manifest "new.txt" ["c9"]);
      run "manifests" Manifests;
      p "\n== a path, with a chunk missing from the source\n";
      ignore (main.delete (Key.chunk d (chunk "c9")));
      run "path" (Path "docs");
      put_chunk "c9";
      run "path" (Path "docs");
      p "\n== a collection open\n";
      Gc_record.write main d
        {
          phase = Marking;
          started = Unix.gettimeofday () -. (3. *. 86400.);
          cursor = "";
          generation = None;
        };
      run "all" All;
      run "manifests" Manifests;
      Gc_record.clear main d;
      p "\n== an unknown source\n";
      run "source" ~source:"nowhere" All);
  Fs.rm_rf root
