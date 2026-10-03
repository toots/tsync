open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-moved-edit-%d" (Unix.getpid ()))

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
    | Engine.Hold r ->
        p "holds: %s\n" r;
        ignore (E.resync ())
    | Incremental -> ()

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      let both = [("A", a); ("B", b)] in
      p "== A edits a published file, then renames it before the upload runs\n";
      write a "a.txt" "version one";
      drain a;
      pass b;
      A.set_paused true;
      write a "a.txt" "version two";
      A.rename ~src:"a.txt" ~dst:"b.txt" ~exclusive:false;
      A.set_paused false;
      drain a;
      pass b;
      pass a;
      show "after both passes" both;
      p "== A edits part of a file in place while B replaces it\n";
      write a "f.txt" "aaaabbbbccccdddd";
      drain a;
      pass b;
      A.set_paused true;
      A.write "f.txt" ~off:4 (Bigstring.of_string "XXXX");
      A.close "f.txt";
      write b "f.txt" "B's whole new text";
      drain b;
      A.set_paused false;
      drain a;
      pass b;
      pass a;
      show "after both passes" both;
      p "== B edits a file offline while A's rename of it arrives\n";
      write a "g.txt" "original";
      drain a;
      pass b;
      A.rename ~src:"g.txt" ~dst:"h.txt" ~exclusive:false;
      drain a;
      B.set_paused true;
      write b "g.txt" "B's edit";
      pass b;
      B.set_paused false;
      drain b;
      pass a;
      show "after both passes" both;
      let c = client "C" in
      let (module C) = c in
      C.start ~poll_journal:false ();
      pass c;
      show "a new client, rebuilt from the store" [("C", c)];
      p "\nowed: A %d/%d, B %d/%d\n" (A.pending_uploads ())
        (A.pending_metadata ()) (B.pending_uploads ()) (B.pending_metadata ()));
  Fs.rm_rf root
