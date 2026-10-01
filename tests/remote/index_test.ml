(* The folder index (spec 02 §2.10, §4.6, §5 "Folder index"): reads and index
   writes counted on a store whose listings carry entity tags. *)

open Tsync_core
open Tsync_store
open Tsync_remote

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-index-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let inner = Local.create ~name:"main" (Filename.concat root "main") in
  let child_reads = ref 0 and index_reads = ref 0 and index_writes = ref 0 in
  let is_index k = Key.leaf k = ".tsync-index" in
  let tagged =
    {
      inner with
      get_many = None;
      list_prefix =
        (fun ?max_keys p ->
          List.map
            (fun (e : Store.entry) ->
              {
                e with
                etag =
                  Option.map
                    (fun b ->
                      Digest.to_hex (Digest.string (Bigstring.to_string b)))
                    (inner.get_opt e.key);
              })
            (inner.list_prefix ?max_keys p));
      get_opt =
        (fun k ->
          if is_index k then incr index_reads else incr child_reads;
          inner.get_opt k);
      put =
        (fun ?mode k b ->
          if is_index k then incr index_writes;
          inner.put ?mode k b);
    }
  in
  let context members =
    let composite =
      Composite.create ~domain:d
        ~data_dir:(Filename.concat root "data")
        ~owner:true ~poke:ignore
        ~knowledge:{ Composite.is_index; is_journal = (fun _ -> false) }
        members
    in
    (module struct
      let domain = d
      let store = Composite.store composite
      let composite = composite
      let versioning = true
      let chunk_size_config = None
      let max_downloads = 1
      let max_chunk_buffers = 4
    end : Context.S)
  in
  let cs = Chunking.chunk_size_min in
  let manifest name =
    (Manifest.make ~name ~size:0 ~mtime:0. ~chunk_size:cs
       [Chunk_key.of_body ""])
      .body
  in
  Rt.run_sync (fun () ->
      inner.put (Key.chunk d (Chunk_key.of_body "")) Bigstring.empty;
      List.iter
        (fun n ->
          inner.put
            (Key.child d Folder_id.root n)
            (Bigstring.of_string (manifest n)))
        ["a"; "b"; "c"];
      let module T =
        Tree.Make
          ((val context [{ name = "main"; role = Main; store = tagged }])) in
      let read label ?write_index () =
        child_reads := 0;
        index_reads := 0;
        index_writes := 0;
        let n = List.length (T.children ?write_index Folder_id.root) in
        p "%-44s %d children: %d child reads, %d index reads, %d index writes\n"
          label n !child_reads !index_reads !index_writes
      in
      read "no index, a reader that may not write" ();
      read "no index, the rebuild walker" ~write_index:true ();
      read "a valid index" ~write_index:true ();
      inner.put
        (Key.child d Folder_id.root "b")
        (Bigstring.of_string (manifest "b2"));
      read "one child rewritten" ~write_index:true ();
      read "the index rewritten" ~write_index:true ();
      inner.put (Key.index d Folder_id.root) (Bigstring.of_string "garbage");
      read "an index that does not parse" ();
      let module T2 =
        Tree.Make
          ((val context
                  [
                    { name = "main"; role = Main; store = tagged };
                    {
                      name = "copy";
                      role = Replica;
                      store =
                        Local.create ~name:"copy" (Filename.concat root "copy");
                    };
                  ])) in
      child_reads := 0;
      index_reads := 0;
      index_writes := 0;
      let n = List.length (T2.children ~write_index:true Folder_id.root) in
      p "%-44s %d children: %d child reads, %d index reads, %d index writes\n"
        "two readable members" n !child_reads !index_reads !index_writes;
      p "a rewritten child reads its new body: %b\n"
        (List.exists
           (fun (e : Tree.entry) ->
             match e.body with File m -> m.name = "b2" | _ -> false)
           (T.children Folder_id.root)));
  Fs.rm_rf root
