(* Import (spec 05 §4.3, §4.2, durable-queue §7.3) from a real directory
   into one client, seen by another through the journal. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-import-%d" (Unix.getpid ()))

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
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  (module Engine.Make (C))

let tree (module E : Engine.S) =
  let rec walk path =
    List.concat_map
      (fun (e : E.entry) ->
        let p = Names.join path e.name in
        if e.is_dir then (p ^ "/") :: walk p
        else (
          let h = E.open_read p in
          let content =
            Fun.protect
              ~finally:(fun () -> E.close_read h)
              (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:1000))
          in
          [
            Printf.sprintf "%s = %S%s" p content
              (if e.st.staged then " (staged)" else "");
          ]))
      (E.list_children path)
  in
  walk ""

let show label clients =
  p "-- %s\n" label;
  List.iter
    (fun (n, c) -> p "  %s: %s\n" n (String.concat "  " (tree c)))
    clients

let drain (module E : Engine.S) = E.drain ~grace:10. ()

let pass (module E : Engine.S) =
  (match E.apply_pass () with
    | _ -> ()
    | exception e -> p "pass failed: %s\n" (Printexc.to_string e));
  match E.bridge () with
    | Engine.Hold r ->
        p "holds: %s\n" r;
        ignore (E.resync ())
    | Incremental -> ()

let report (r : Import_plan.report) =
  p "imported %d (%d bytes), skipped %d, links skipped %d, failed %d%s\n"
    r.imported r.bytes r.skipped r.skipped_symlinks (List.length r.failed)
    (if r.cancelled then ", cancelled" else "");
  List.iter (fun (path, reason) -> p "  %s: %s\n" path reason) r.failed

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  let file rel body =
    let path = Filename.concat src rel in
    Fs.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc body)
  in
  file "top.txt" "top";
  file "notes/a.txt" "alpha";
  file "notes/deep/b.txt" "a body longer than one chunk";
  Fs.mkdir_p (Filename.concat src "empty");
  Unix.symlink "top.txt" (Filename.concat src "top-link");
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      let both = [("A", a); ("B", b)] in
      p "== A imports a tree, B applies the journal\n";
      report (A.import src);
      drain a;
      pass b;
      show "after B's pass" both;
      p "\n== a rerun finds everything there\n";
      report (A.import src);
      drain a;
      p "entries B applies: %d\n" (B.apply_pass ());
      p "\n== a changed file stays skipped unless forced\n";
      file "top.txt" "top, changed";
      report (A.import ~only:["top.txt"] src);
      report (A.import ~only:["top.txt"] ~force_rehash:true src);
      drain a;
      pass b;
      show "after B's pass" [("B", b)];
      p "\n== cancelled partway: only what was uploaded is announced\n";
      file "more/one.txt" "one";
      file "more/two.txt" "two";
      file "more/three.txt" "three";
      let checks = ref 0 in
      let cancelled () =
        incr checks;
        !checks > 4
      in
      report (A.import ~only:["more/**"] ~cancelled src);
      drain a;
      pass b;
      show "after B's pass" [("B", b)];
      report (A.import ~only:["more/**"] src);
      drain a;
      pass b;
      show "after the rerun" [("B", b)];
      p "\nowed: A %d/%d, unapplied B %d\n" (A.pending_uploads ())
        (A.pending_metadata ())
        (List.length (B.unapplied ())));
  Fs.rm_rf root
