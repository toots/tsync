(* File ids (01 §2.7, 04 §2.3): kept across renames, rewrites and peers'
   changes, carried into the applied log, and given at owner start to files
   found without one. *)

open Tsync_core
open Tsync_store
open Tsync_checkout
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-file-ids-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

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
    let client_uuid = Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  (module Engine.Make (C))

(* Random ids print as <idN>, numbered by first appearance. *)
let aliases = Hashtbl.create 16

let alias id =
  match Hashtbl.find_opt aliases id with
    | Some a -> a
    | None ->
        let a = Printf.sprintf "<id%d>" (Hashtbl.length aliases + 1) in
        Hashtbl.replace aliases id a;
        a

let id_at (module E : Engine.S) path =
  match Mirror.file_id E.mirror path with Some id -> alias id | None -> "none"

let show name c paths =
  p "  %s: %s\n" name
    (String.concat "  "
       (List.map (fun path -> path ^ "=" ^ id_at c path) paths))

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let drain (module E : Engine.S) = E.drain ~grace:10. ()

let pass (module E : Engine.S) =
  (match E.apply_pass () with
    | _ -> ()
    | exception e -> p "pass failed: %s\n" (Printexc.to_string e));
  match E.bridge () with
    | Engine.Hold _ -> ignore (E.resync ())
    | Incremental -> ()

let op_name = function
  | Op.Put { path; _ } -> "put " ^ path
  | Delete path -> "delete " ^ path
  | Mkdir { path; _ } -> "mkdir " ^ path
  | Rmdir { path; _ } -> "rmdir " ^ path
  | Rename { src; dst; _ } -> "rename " ^ src ^ "->" ^ dst

let feed name (module E : Engine.S) =
  p "  %s's applied log:\n" name;
  match Applied.since E.applied None 1000 with
    | `Stale -> p "    stale\n"
    | `Page pg ->
        List.iter
          (fun (_, (ops : Applied.op list)) ->
            List.iter
              (fun (o : Applied.op) ->
                p "    %-24s fid=%s\n" (op_name o.op)
                  (match o.fid with Some id -> alias id | None -> "-"))
              ops)
          pg.entries

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      p "== a staged-only file has an id, kept through publish\n";
      write a "x.txt" "one";
      show "A staged" a ["x.txt"];
      drain a;
      show "A published" a ["x.txt"];
      p "== a rename and a rewrite keep it; a peer mints its own\n";
      let x = Option.get (Mirror.file_id A.mirror "x.txt") in
      p "  %s resolves to %s\n" (alias x)
        (Option.value ~default:"nothing" (Mirror.path_of_file_id A.mirror x));
      A.rename ~src:"x.txt" ~dst:"y.txt" ~exclusive:false;
      p "  %s resolves to %s\n" (alias x)
        (Option.value ~default:"nothing" (Mirror.path_of_file_id A.mirror x));
      write a "y.txt" "two";
      drain a;
      pass b;
      show "A" a ["x.txt"; "y.txt"];
      show "B" b ["y.txt"];
      p "== a peer's rename keeps the receiver's id\n";
      A.rename ~src:"y.txt" ~dst:"z.txt" ~exclusive:false;
      drain a;
      pass b;
      show "B" b ["y.txt"; "z.txt"];
      p "== a rename onto a file gives the destination the source's id\n";
      write a "p.txt" "p";
      write a "q.txt" "q";
      drain a;
      show "A before" a ["p.txt"; "q.txt"];
      A.rename ~src:"p.txt" ~dst:"q.txt" ~exclusive:false;
      drain a;
      show "A after" a ["p.txt"; "q.txt"];
      p "== a folder move carries its files' ids, and they resolve there\n";
      A.mkdir "dir" ~exclusive:false;
      write a "dir/f.txt" "f";
      drain a;
      let fid = Option.get (Mirror.file_id A.mirror "dir/f.txt") in
      A.rename ~src:"dir" ~dst:"moved" ~exclusive:false;
      drain a;
      p "  %s resolves to %s\n" (alias fid)
        (Option.value ~default:"nothing" (Mirror.path_of_file_id A.mirror fid));
      p "== deletes are noted with the id the file had\n";
      A.delete "z.txt";
      drain a;
      pass b;
      show "B" b ["z.txt"];
      feed "A" a;
      feed "B" b;
      let last_applied (module E : Engine.S) =
        match Applied.since E.applied None 1000 with
          | `Page pg -> (
              match List.rev pg.entries with
                | (_, ops) :: _ ->
                    List.iter
                      (fun (o : Applied.op) ->
                        p "  last applied: %s fid=%s\n" (op_name o.op)
                          (match o.fid with Some id -> alias id | None -> "-"))
                      ops
                | [] -> p "  the applied log is empty\n")
          | `Stale -> p "  stale\n"
      in
      let peer_delete_under_renamed_folder ~published x y =
        A.mkdir x ~exclusive:false;
        write a (x ^ "/f.txt") "f";
        drain a;
        pass b;
        p "  B's %s/f.txt: %s\n" x
          (alias (Option.get (Mirror.file_id B.mirror (x ^ "/f.txt"))));
        if not published then B.set_paused true;
        B.rename ~src:x ~dst:y ~exclusive:false;
        drain b;
        A.delete (x ^ "/f.txt");
        drain a;
        pass b;
        show "B" b [y ^ "/f.txt"];
        last_applied b;
        B.set_paused false;
        drain b
      in
      p "== a peer's delete under a folder renamed here, rename unpublished\n";
      peer_delete_under_renamed_folder ~published:false "X" "Y";
      p "== the same with the rename published: the file is kept, no id named\n";
      peer_delete_under_renamed_folder ~published:true "X2" "Y2";
      p "== owner start gives an id to a file found without one\n";
      let marker =
        Filename.concat (Mirror.path B.mirror "")
          (".tsync-fid-" ^ Xxh.hex16 (Xxh.string "q.txt"))
      in
      pass b;
      show "B before" b ["q.txt"];
      Fs.unlink_quiet marker;
      show "B without its marker" b ["q.txt"];
      p "  a start after a complete pass: %d\n"
        (Mirror.backfill_file_ids B.mirror);
      (* An install from before file ids has no record of a pass. *)
      Fs.unlink_quiet
        (Filename.concat (Mirror.root B.mirror) "file-ids-complete");
      p "  the first pass: %d\n" (Mirror.backfill_file_ids B.mirror);
      show "B after" b ["q.txt"];
      p "  the next one: %d\n" (Mirror.backfill_file_ids B.mirror);
      (* A second mirror over A's directory is a restarted owner. *)
      let restarted () =
        Mirror.create ~cache_root:(Filename.dirname (Mirror.root A.mirror)) d
      in
      let snapshot = Filename.concat (Mirror.root A.mirror) "file-ids-index" in
      let resolves m id =
        Option.value ~default:"nothing" (Mirror.path_of_file_id m id)
      in
      p "== a clean stop keeps the index for the next start\n";
      drain a;
      p "  snapshot after the stop: %b\n" (Sys.file_exists snapshot);
      let m = restarted () in
      Mirror.load_file_ids m;
      p "  snapshot after the start: %b\n" (Sys.file_exists snapshot);
      p "  %s resolves to %s\n" (alias fid) (resolves m fid);
      p "== a marker change after the stop removes the snapshot\n";
      drain a;
      p "  snapshot after the stop: %b\n" (Sys.file_exists snapshot);
      write a "late.txt" "late";
      p "  snapshot: %b\n" (Sys.file_exists snapshot);
      drain a;
      p
        "== without a snapshot the start builds it, with changes made meanwhile\n";
      (* A crash leaves none. *)
      Fs.unlink_quiet snapshot;
      let m = restarted () in
      Mirror.load_file_ids m;
      Mirror.write_file m "during.txt"
        (Manifest.make ~name:"during.txt" ~size:1 ~mtime:0. ~chunk_size:4
           [Chunk_key.of_bigstring (Bigstring.of_string "x")]);
      let during = Mirror.ensure_file_id m "during.txt" in
      p "  %s resolves to %s\n" (alias fid) (resolves m fid);
      p "  the id minted during the build resolves to %s\n" (resolves m during));
  (* pitfall B-12.11: a store's background work may still write under the
     root while this removes it.
     ponytail: retried, as in tests/gc/resume_test.ml; stopping the store's
     background work would end the race for every test. *)
  let rec remove n =
    try Fs.rm_rf root
    with _ when n > 0 ->
      Unix.sleepf 0.2;
      remove (n - 1)
  in
  remove 10
