(* Rsync (spec 05 §4.5) between a local directory and a domain and within
   the domain, run on one client and seen by another through the journal. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-rsync-%d" (Unix.getpid ()))

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

let shape label (module E : Engine.S) =
  let rec walk path =
    List.concat_map
      (fun (e : E.entry) ->
        let p = Names.join path e.name in
        if e.is_dir then (p ^ "/") :: walk p
        else [Printf.sprintf "%s (%d)" p e.st.size])
      (E.list_children path)
  in
  p "-- %s\n  %s\n" label (String.concat "  " (walk ""))

let report (r : Rsync_plan.report) =
  p "copied %d (%d bytes), identical %d, folders %d, skipped %d, failed %d%s\n"
    r.copied r.bytes_moved r.identical r.dirs (List.length r.skipped)
    (List.length r.failed)
    (if r.cancelled then ", cancelled" else "");
  List.iter
    (fun (path, why) ->
      p "  skipped %s: %s\n" (if path = "" then "." else path) why)
    r.skipped;
  List.iter (fun (path, why) -> p "  failed %s: %s\n" path why) r.failed

let plan (r : Rsync_plan.report) =
  List.iter
    (fun (rel, d) ->
      p "  %s: %s\n" (if rel = "" then "." else rel) (Rsync_plan.describe d))
    r.planned

let local path : Rsync_plan.endpoint = { side = Local; path }
let domain path : Rsync_plan.endpoint = { side = Domain; path }

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" and out = Filename.concat root "out" in
  let file base rel body =
    let path = Filename.concat base rel in
    Fs.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc body)
  in
  let read base rel =
    In_channel.with_open_bin (Filename.concat base rel) In_channel.input_all
  in
  let big =
    Random.init 42;
    String.init 210000 (fun _ -> Char.chr (Random.int 256))
  in
  file src "top.txt" "top";
  file src "notes/a.txt" "alpha";
  file src "notes/big.bin" big;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      let rs ?move ?dry_run s d = A.rsync ?move ?dry_run ~src:s ~dst:d () in
      p "== local to the domain, a dry run first\n";
      plan (rs ~dry_run:true (local src) (domain "dest"));
      report (rs (local src) (domain "dest"));
      drain a;
      pass b;
      shape "B sees" b;
      p "\n== again: everything identical\n";
      report (rs (local src) (domain "dest"));
      p "\n== one local chunk changed is uploaded again\n";
      file src "notes/big.bin"
        (String.mapi (fun i c -> if i = 75000 then 'Z' else c) big);
      report (rs (local src) (domain "dest"));
      (* Published first: an unpublished edit is not copied (05 rsync). *)
      drain a;
      p "\n== out of the domain, then one local chunk off is patched\n";
      report (rs (domain "dest") (local out));
      p "big.bin equal: %b\n"
        (read out "notes/big.bin" = read src "notes/big.bin");
      file out "notes/big.bin"
        (String.mapi
           (fun i c -> if i = 150 then 'Q' else c)
           (read out "notes/big.bin"));
      plan
        (rs ~dry_run:true (domain "dest/notes")
           (local (Filename.concat out "notes")));
      report (rs (domain "dest/notes") (local (Filename.concat out "notes")));
      p "big.bin equal again: %b\n"
        (read out "notes/big.bin" = read src "notes/big.bin");
      p "\n== a copy, then a move, within the domain\n";
      report (rs (domain "dest/notes") (domain "copy"));
      report (rs ~move:true (domain "copy") (domain "moved"));
      drain a;
      pass b;
      shape "B sees" b;
      p "\n== a local move drops the local sources\n";
      file src "inbox/x.txt" "x";
      file src "inbox/y.txt" "y";
      report
        (rs ~move:true (local (Filename.concat src "inbox")) (domain "inbox"));
      p "local inbox now: [%s]\n"
        (String.concat "; "
           (Array.to_list (Sys.readdir (Filename.concat src "inbox"))));
      drain a;
      pass b;
      shape "B sees" b;
      p "\n== a move leaves a file with an unpublished edit where it is\n";
      let put path body =
        A.create path ~exclusive:false;
        A.write path ~off:0 (Bigstring.of_string body);
        A.close path
      in
      put "pend/f.txt" "published";
      put "pend/g.txt" "g";
      drain a;
      A.set_paused true;
      put "pend/f.txt" "edited here";
      report (rs ~move:true (domain "pend") (domain "pend2"));
      p "pend2/f.txt copied: %b; pend/f.txt kept: %b; pend2/g.txt copied: %b\n"
        (A.kind "pend2/f.txt" = `File)
        (A.kind "pend/f.txt" = `File)
        (A.kind "pend2/g.txt" = `File);
      A.set_paused false;
      drain a;
      p "\n== a move cancelled mid-batch announces only the moves made\n";
      List.iter
        (fun n -> put ("mv/" ^ n) n)
        ["a.txt"; "b.txt"; "c.txt"; "d.txt"];
      drain a;
      pass b;
      report
        (A.rsync ~move:true
           ~cancelled:(fun () -> A.kind "mv2/b.txt" = `File)
           ~src:(domain "mv") ~dst:(domain "mv2") ());
      drain a;
      pass b;
      let files (module E : Engine.S) dir =
        String.concat " "
          (List.map (fun (e : E.entry) -> e.name) (E.list_children dir))
      in
      p "A: mv [%s] mv2 [%s]\n" (files a "mv") (files a "mv2");
      p "B: mv [%s] mv2 [%s]\n" (files b "mv") (files b "mv2");
      p "\n== refusals\n";
      report (rs (local src) (domain "dest/top.txt"));
      drain a;
      p "\nowed: A %d/%d, unapplied B %d\n" (A.pending_uploads ())
        (A.pending_metadata ())
        (List.length (B.unapplied ())));
  Fs.rm_rf root
