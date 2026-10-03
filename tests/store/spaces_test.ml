(* The collectable local driver scopes every chunk access with the collection
   (spec algorithms/gc.md §5.4, §5.8): callers see one chunk space. *)

open Tsync_core
open Tsync_store

let p = Contract.p
let d = Domain_name.v "d"
let kind = Contract.kind_of

let manifest_body cks =
  let cs = Chunking.chunk_size_min in
  (Manifest.make ~name:"f"
     ~size:(List.length cks * cs)
     ~mtime:0. ~chunk_size:cs cks)
    .body

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-spaces-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let file rel = Filename.concat root rel in
  let on_disk key = Fs.exists (file (Key.to_string key)) in
  let s = Local.create ~name:"main" root in
  let ck n = Chunk_key.of_body n in
  let c1 = ck "one" and c2 = ck "two" and c3 = ck "three" and c4 = ck "four" in
  let slot n = Key.v ("tsync/d/manifests/.tsync-root/" ^ n) in
  let listing prefix =
    String.concat " "
      (List.map
         (fun (e : Store.entry) ->
           match Key.chunk_parts e.key with
             | Some (_, c) when Chunk_key.equal c c1 -> "one"
             | Some (_, c) when Chunk_key.equal c c2 -> "two"
             | Some (_, c) when Chunk_key.equal c c4 -> "four"
             | _ -> Key.rel (Key.prefix "tsync/d/") e.key)
         (s.list_prefix (Key.prefix prefix)))
  in
  Rt.run_sync (fun () ->
      p "== the gate with no run open\n";
      Contract.put s (Key.chunk d c1) "one";
      Contract.put s (Key.chunk d c2) "two";
      p "manifest naming present chunks: %s\n"
        (kind (fun () -> Contract.put s (slot "a") (manifest_body [c1])));
      Contract.put s (slot "b") (manifest_body [c2]);
      p "manifest naming an absent chunk: %s\n"
        (kind (fun () -> Contract.put s (slot "x") (manifest_body [c3])));
      p "refused manifest not written: %b\n" (not (on_disk (slot "x")));
      p "folder marker: %s\n"
        (kind (fun () ->
             Contract.put s (slot "m")
               {|{"dir":true,"name":"m","id":"0123456789ab-1"}|}));
      p "JSON that is not a folder marker: %s\n"
        (kind (fun () -> Contract.put s (slot "j") {|{"id":"x"}|}));
      p "folder index (internal leaf): %s\n"
        (kind (fun () -> Contract.put s (slot ".tsync-index") "tsyncidx1..."));
      p "body that is neither: %s\n"
        (kind (fun () -> Contract.put s (slot "y") "garbage"));
      p "claim naming an absent chunk: %s\n"
        (kind (fun () -> Contract.claim s (slot "z") (manifest_body [c3])));
      p "copy into the version area: %s\n"
        (kind (fun () -> s.copy (slot "a") (Key.v "tsync/d/versions/g/h/1")));
      p "\n== a run opens: R written, S renamed to F\n";
      Fs.write_file_for_test (file (Key.to_string (Key.gc_run d))) "{}";
      Unix.rename (file "tsync/d/chunks") (file "tsync/d/chunks.from");
      p "get one: %s; head two: %b; range one: %s\n"
        (Contract.show (Contract.get s (Key.chunk d c1)))
        (s.head_opt (Key.chunk d c2) <> None)
        (Contract.show (Contract.range s (Key.chunk d c1) 1 5));
      Contract.put s (Key.chunk d c4) "four";
      p "chunk put lands in S: %b\n" (on_disk (Key.chunk d c4));
      Fs.write_file_for_test (file (Key.to_string (Key.chunk_from d c4))) "four";
      p "listing the chunk area: %s\n" (listing "tsync/d/chunks/");
      p "listing one shard: %s\n"
        (listing
           (Key.prefix_to_string (Key.shard_prefix d (Chunk_key.shard c2))));
      p "listing the domain names no outgoing key: %b\n"
        (not
           (List.exists
              (fun (e : Store.entry) -> Key.is_outgoing e.key)
              (s.list_prefix (Key.domain_prefix d))));
      p "\n== publications during the run promote\n";
      Contract.put s (slot "a") (manifest_body [c1]);
      p "put promotes one: in S %b, in F %b\n"
        (on_disk (Key.chunk d c1))
        (on_disk (Key.chunk_from d c1));
      s.copy (slot "b") (slot "c");
      p "copy promotes two: in S %b, in F %b\n"
        (on_disk (Key.chunk d c2))
        (on_disk (Key.chunk_from d c2));
      ignore (s.delete (Key.chunk d c4));
      p "delete removes both spaces: S %b, F %b\n"
        (on_disk (Key.chunk d c4))
        (on_disk (Key.chunk_from d c4));
      p "\n== the publish lock orders publications with the collector\n";
      let spaces = Chunk_spaces.create root in
      let held = Rt.Promise.create () and release = Rt.Promise.create () in
      let collector =
        Rt.async (fun () ->
            Chunk_spaces.with_publish_lock spaces d ~exclusive:true (fun () ->
                Rt.Promise.resolve held ();
                Rt.Promise.await release))
      in
      Rt.Promise.await held;
      let done_ = Atomic.make false in
      let writer =
        Rt.async (fun () ->
            Contract.put s (slot "e") (manifest_body [c1]);
            Atomic.set done_ true)
      in
      Rt.sleep 0.3;
      p "publication waits while the lock is held: %b\n"
        (not (Atomic.get done_));
      p "a record naming no chunk does not wait: %s\n"
        (kind (fun () ->
             Contract.put s (slot "n")
               {|{"dir":true,"name":"n","id":"0123456789ab-1"}|}));
      Rt.Promise.resolve release ();
      Rt.Promise.await collector;
      Rt.Promise.await writer;
      p "publication completes once released: %b\n" (Atomic.get done_);
      p "\n== the run ends\n";
      Fs.rm_rf (file "tsync/d/chunks.from");
      Unix.unlink (file (Key.to_string (Key.gc_run d)));
      p "promoted chunks read: %b %b\n"
        (Contract.get s (Key.chunk d c1) <> None)
        (Contract.get s (Key.chunk d c2) <> None);
      p "absent chunk: %s\n" (Contract.show (Contract.get s (Key.chunk d c3))));
  Fs.rm_rf root
