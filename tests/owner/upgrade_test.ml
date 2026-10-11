(* The one-off upgrade from the journal protocol, on a store laid out as that
   protocol left it: what a client sees if it arrives before the cleanup, the
   dry run, the cleanup, and the arrival after it. Deleted with [Upgrade]. *)

open Tsync_core
open Tsync_store
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-upgrade-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"d","symlinks":"keep","versioning":false,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let d = Domain_name.v "d"

let () =
  Rt.run_sync (fun () ->
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let put key body = main.put key (Bigstring.of_string body) in
      let raw rel body =
        let path =
          Filename.concat (Filename.concat root "store") ("tsync/d/" ^ rel)
        in
        Fs.mkdir_p (Filename.dirname path);
        Fs.write_file_for_test path body
      in
      let id n = Folder_id.mint ~uuid:"aaaaaaaaaaaa" ~counter:n in
      let chunk = Chunk_key.of_body "" in
      put (Key.chunk d chunk) "";
      let file parent name =
        put (Key.child d parent name)
          (Manifest.make ~name ~size:0 ~mtime:0.
             ~chunk_size:Chunking.chunk_size_min [chunk])
            .body
      in
      let folder ?(under = Folder_id.to_string Folder_id.root) parent name i =
        put (Key.child d parent name) (Folder.marker_body { name; id = i });
        raw
          (Printf.sprintf "manifests/%s/.tsync-parent" (Folder_id.to_string i))
          (Printf.sprintf {|{"parent":%S,"name":%S}|} under name)
      in
      let live = id 1 and binned = id 2 and inner = id 3 in
      folder Folder_id.root "live" live;
      file live "kept.txt";
      file Folder_id.root "top.txt";
      (* A trashed folder with a folder in it: anchored in the trash, a trash
         entry naming it, no live marker. *)
      raw
        (Printf.sprintf "manifests/%s/.tsync-parent"
           (Folder_id.to_string binned))
        {|{"parent":".tsync-trash","name":"binned"}|};
      raw "manifests/.tsync-trash/e1"
        (Printf.sprintf {|{"dir":true,"name":"binned","id":%S,"path":"binned"}|}
           (Folder_id.to_string binned));
      file binned "old.txt";
      folder ~under:(Folder_id.to_string binned) binned "inner" inner;
      file inner "deep.txt";
      raw "journal/2026-10/1790000000000-abc"
        "{\"op\":\"delete\",\"key\":\"x\"}\n";
      raw "cursor" "1790000000000-abc";
      let dom =
        Tsync_domain.Domain.build ~owner:true config (List.hd config.domains)
      in
      let (module E) = Tsync_domain.Domain.engine dom in
      let wal =
        List.fold_left Filename.concat dom.data_dir ["journal-pending"; "d"]
      in
      Fs.mkdir_p wal;
      Fs.write_file_for_test (Filename.concat wal "1790000000001-abc") "{}";
      Fs.write_file_for_test (Filename.concat dom.data_dir "last-sync-d") "x";
      let tree () =
        String.concat " " (List.map (fun (path, _) -> path) (E.list_tree ""))
      in
      let upgrade ~apply ~discard =
        p "  exit %d"
          (Upgrade.run ~out:(p "  %s") ~cancelled:(Fun.const false) dom ~apply
             ~discard)
      in
      p "== unpublished records of the previous version";
      upgrade ~apply:true ~discard:false;
      p "== a dry run";
      upgrade ~apply:false ~discard:true;
      p "  the journal is still there: %b"
        (main.list_prefix (Key.prefix "tsync/d/journal/") <> []);
      p "== a client that arrives before the cleanup sees the live tree only";
      E.start ~background:false ();
      ignore (E.resync ());
      p "  %s" (tree ());
      p "== the cleanup";
      upgrade ~apply:true ~discard:true;
      p "  left on the store:";
      List.iter
        (fun (e : Store.entry) ->
          p "    %s"
            (Text.replace_all ~sub:(Folder_id.to_string live) ~by:"<live>"
               (Key.to_string e.key)))
        (main.list_prefix (Key.domain_prefix d));
      p "  left here: WAL %b, mark %b" (Fs.exists wal)
        (Fs.exists (Filename.concat dom.data_dir "last-sync-d"));
      p "== again: nothing to do";
      upgrade ~apply:true ~discard:false;
      p "== an arrival by state after it, then a first commit";
      ignore (E.resync ~full:true ());
      p "  %s" (tree ());
      E.mkdir "new" ~exclusive:false;
      let r = E.resync () in
      p "  committed %d, pending %d; the log's first entry exists: %b"
        r.committed r.pending
        (main.head_opt (Key.log_entry d 1) <> None);
      let module I =
        Tsync_gc.Integrity.Make ((val Tsync_domain.Domain.context dom)) in
      p "  the tree report is healthy: %b"
        (Tsync_gc.Integrity.healthy (I.report ())));
  Test_support.finish root
