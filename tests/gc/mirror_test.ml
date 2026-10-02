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
  (* The copy behaves as a bucket: its entries carry the MD5 its service
     keeps, it is Remote, and every read of it is counted. *)
  let reads = ref 0 and checksums = ref 0 in
  let race = ref None and unguarded = ref false in
  let kept (e : Store.entry) =
    {
      e with
      checksum =
        Option.map (Checksum.of_body Checksum.md5) (inner.get_opt e.key);
    }
  in
  let copy =
    {
      inner with
      put =
        (fun ?mode k b ->
          order := Key.to_string k :: !order;
          inner.put ?mode k b);
      put_if_unchanged =
        (fun k b expected ->
          order := Key.to_string k :: !order;
          if !unguarded then Fail.raise_ Fail.Refused "no preconditions here";
          (match !race with
            | Some (rk, body) when Key.equal rk k ->
                race := None;
                inner.put k (Bigstring.of_string body)
            | _ -> ());
          inner.put_if_unchanged k b expected);
      get_opt =
        (fun k ->
          incr reads;
          inner.get_opt k);
      compute_checksum =
        (fun k algo ->
          incr checksums;
          inner.compute_checksum k algo);
      head_opt = (fun k -> Option.map kept (inner.head_opt k));
      list_prefix =
        (fun ?max_keys p -> List.map kept (inner.list_prefix ?max_keys p));
      locality = Remote;
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
                    "%s: %s -> %s, %d checked, %d copied (%d bytes), %d \
                     refused, %d changed, %d unguarded\n"
                    label r.source c.name c.checked c.copied c.copied_bytes
                    (List.length c.failed) c.changed c.unguarded)
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
      p "\n== progress\n";
      let shards = ref [] and lines = ref [] and said = ref [] in
      let narrate =
        {
          Narrate.say = (fun s -> said := s :: !said);
          progress =
            (fun ?fraction text ->
              lines := text :: !lines;
              if Text.contains text "chunk shard" then
                shards := Option.value ~default:(-1.) fraction :: !shards);
        }
      in
      ignore (M.mirror ~narrate All);
      let fractions = List.rev !shards in
      let rec rising = function
        | a :: (b :: _ as rest) -> a <= b && rising rest
        | _ -> true
      in
      p "chunk shard progress never goes back: %b, ends at 1: %b\n"
        (rising fractions)
        (List.nth_opt (List.rev fractions) 0 = Some 1.);
      let lines = List.rev !lines in
      let first f =
        let rec go i = function
          | [] -> -1
          | l :: rest -> if f l then i else go (i + 1) rest
        in
        go 0 lines
      in
      p "manifests listings shown before comparing: %b\n"
        (let listing = first (fun l -> Text.contains l "manifests, listing")
         and comparing = first (fun l -> Text.contains l "manifests, 1 of") in
         listing >= 0 && listing < comparing);
      List.iter
        (fun s -> if Text.contains s "listed" then p "said:%s\n" s)
        (List.rev !said);
      p "\n== again\n";
      reads := 0;
      checksums := 0;
      run "all" All;
      p "reads of the copy: %d, checksums computed on it: %d\n" !reads
        !checksums;
      p "\n== a changed manifest and a short chunk on the copy\n";
      put (Key.child d Folder_id.root "a.txt") (manifest "a.txt" ["c2"]);
      inner.put (Key.chunk d (chunk "c3")) (Bigstring.of_string "c");
      run "all" All;
      p "\n== a manifest written on the copy after it was compared\n";
      put (Key.child d Folder_id.root "a.txt") (manifest "a.txt" ["c3"]);
      let meanwhile = manifest "a.txt" ["c2"; "c3"] in
      race := Some (Key.child d Folder_id.root "a.txt", meanwhile);
      run "all" All;
      p "the copy keeps the other write: %b\n"
        (Option.map Bigstring.to_string
           (inner.get_opt (Key.child d Folder_id.root "a.txt"))
        = Some meanwhile);
      run "all" All;
      p "\n== a copy that cannot replace conditionally\n";
      put (Key.child d Folder_id.root "a.txt") (manifest "a.txt" ["c1"]);
      unguarded := true;
      run "all" All;
      unguarded := false;
      p "\n== everything but the chunks\n";
      put_chunk "c9";
      put (Key.child d folder "new.txt") (manifest "new.txt" ["c9"]);
      put (Key.journal_entry d ~month:"2026-10" ~entry:"e2") "[]";
      put (Key.cursor d) "e2";
      run "skip-chunks" Skip_chunks;
      p "journal entry and same-size cursor copied: %b\n"
        (inner.head_opt (Key.journal_entry d ~month:"2026-10" ~entry:"e2")
         <> None
        && Option.map Bigstring.to_string (inner.get_opt (Key.cursor d))
           = Some "e2");
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
      run "skip-chunks" Skip_chunks;
      Gc_record.clear main d;
      p "\n== an unknown source\n";
      run "source" ~source:"nowhere" All);
  Fs.rm_rf root
