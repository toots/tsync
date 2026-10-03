open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-two-%d" (Unix.getpid ()))

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
      p "== A creates, B applies\n";
      A.mkdir "papers" ~exclusive:false;
      write a "papers/one.txt" "hello world";
      write a "top.txt" "top";
      drain a;
      if Sys.getenv_opt "DEBUG_STORE" <> None then (
        ignore
          (Sys.command
             (Printf.sprintf "find %s | sort 1>&2" (Filename.quote root)));
        Printf.eprintf "pending uploads %d metadata %d parked %d\n%!"
          (A.pending_uploads ()) (A.pending_metadata ())
          (List.length (A.parked ())));
      pass b;
      show "after B's pass" both;
      p "\n== B edits inside one chunk; A applies\n";
      B.write "papers/one.txt" ~off:6 (Bigstring.of_string "WORLD");
      B.close "papers/one.txt";
      drain b;
      pass a;
      show "after A's pass" both;
      p "\n== renames travel with their folder id\n";
      B.rename ~src:"papers" ~dst:"archive" ~exclusive:false;
      B.rename ~src:"top.txt" ~dst:"archive/top.txt" ~exclusive:false;
      drain b;
      pass a;
      show "after A's pass" both;
      p "\n== edit/edit: B publishes first, A's edit still unpublished (F9)\n";
      A.set_paused true;
      write a "archive/one.txt" "from A";
      write b "archive/one.txt" "from B";
      drain b;
      pass a;
      A.set_paused false;
      drain a;
      pass b;
      show "converged" both;
      p "\n== an unpublished edit outlives a delete (F12)\n";
      B.set_paused true;
      A.delete "archive/top.txt";
      write b "archive/top.txt" "B edits top";
      drain a;
      pass b;
      B.set_paused false;
      drain b;
      pass a;
      show "converged" both;
      p "\n== kind clash: A's file published, B's folder unpublished (K1')\n";
      B.set_paused true;
      write a "x" "a file";
      B.mkdir "x" ~exclusive:false;
      write b "x/in" "inside";
      drain a;
      (match B.bridge () with
        | Engine.Hold r -> p "B holds: %s\n" r
        | Incremental -> ());
      pass b;
      B.set_paused false;
      drain b;
      pass a;
      drain a;
      pass b;
      show "converged" both;
      p "\n== a folder removed while B adds to it, then restored (05 §4.8)\n";
      A.mkdir "box" ~exclusive:false;
      write a "box/a.txt" "first";
      drain a;
      pass b;
      write b "box/b.txt" "added meanwhile";
      drain b;
      A.delete "box/a.txt";
      A.rmdir "box";
      drain a;
      pass b;
      pass a;
      show "box trashed, with B's addition inside" both;
      p "restore: %s\n"
        (match A.restore_from_trash "box" with
          | `Restored n -> Printf.sprintf "%d announced" n
          | `Not_in_trash -> "not in the trash"
          | `Exists -> "name taken");
      p "again: %s\n"
        (match A.restore_from_trash "box" with
          | `Restored n -> Printf.sprintf "%d announced" n
          | `Not_in_trash -> "not in the trash"
          | `Exists -> "name taken");
      drain a;
      pass b;
      show "after B's pass" both;
      p "\n== two additions under A's unpublished rmdir share R(F) (§3.5)\n";
      A.mkdir "crate" ~exclusive:false;
      write a "crate/a.txt" "first";
      drain a;
      pass b;
      A.set_paused true;
      A.delete "crate/a.txt";
      A.rmdir "crate";
      write b "crate/b1.txt" "one";
      drain b;
      write b "crate/b2.txt" "two";
      drain b;
      pass a;
      A.set_paused false;
      drain a;
      pass b;
      drain b;
      pass a;
      show "converged" both;
      p "\n== a file takes the name of a folder removed after an edit in it\n";
      A.mkdir "was-a-folder" ~exclusive:false;
      write a "was-a-folder/f" "inside";
      A.delete "was-a-folder/f";
      A.rmdir "was-a-folder";
      p "create: %s\n"
        (match write a "was-a-folder" "now a file" with
          | () -> "written"
          | exception e -> Printexc.to_string e);
      drain a;
      pass b;
      p "B reads it: %b\n" (B.kind "was-a-folder" = `File);
      p "\n== a file handed over from another filesystem (security §7.3)\n";
      (* The build directory, where this runs, is not the temporary one. *)
      let elsewhere n = Filename.concat (Sys.getcwd ()) ("handed-" ^ n) in
      let secret = elsewhere "secret" and link = elsewhere "link" in
      Fs.write_file_for_test secret "not for the store";
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      Unix.symlink secret link;
      let hand_over name src =
        match A.write_whole name ~src ~exclusive:false () with
          | () -> "adopted"
          | exception Fail.E f -> Fail.kind_name f.kind
      in
      let linked = hand_over "from-link.txt" link in
      p "a link to a file: %s; staged here: %b\n" linked
        (A.kind "from-link.txt" = `File);
      let plain = elsewhere "plain" in
      Fs.write_file_for_test plain "handed over";
      let adopted = hand_over "from-file.txt" plain in
      p "a regular file: %s; the source is gone: %b\n" adopted
        (not (Sys.file_exists plain));
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      Unix.unlink secret;
      drain a;
      pass b;
      show "B reads what was adopted" [("B", b)];
      p "\nowed: A %d/%d, B %d/%d; unapplied: %d %d\n" (A.pending_uploads ())
        (A.pending_metadata ()) (B.pending_uploads ()) (B.pending_metadata ())
        (List.length (A.unapplied ()))
        (List.length (B.unapplied ())));
  Fs.rm_rf root
