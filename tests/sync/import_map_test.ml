open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-import-map-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

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
    let projects_all = false
    let settings _ = (Tuning.default, symlinks)
  end in
  (module Engine.Make (C))

let tree (module E : Engine.S) =
  let rec walk path =
    List.concat_map
      (fun (e : E.entry) ->
        let p = Names.join path e.name in
        if e.is_dir then (p ^ "/", None) :: walk p else [(p, Some e.st.times)])
      (E.list_children path)
  in
  walk ""

let show (module E : Engine.S) ~source_times =
  List.iter
    (fun (path, times) ->
      match times with
        | None -> p "  %s\n" path
        | Some (t : Fs.times) when List.mem_assoc path source_times ->
            p "  %s: the source's times %b\n" path
              (List.assoc path source_times = t)
        | Some t -> p "  %s: mtime %d, created %d\n" path t.mtime t.created)
    (tree (module E))

let report (r : Import_plan.report) =
  p "imported %d, skipped %d, failed %d\n" r.imported r.skipped
    (List.length r.failed);
  List.iter
    (fun (path, reason) -> p "  %s failed: %b\n" path (reason <> ""))
    r.failed

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  let file rel body =
    let path = Filename.concat src rel in
    Fs.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc body)
  in
  file "x/one.txt" "one";
  file "y/z/two.txt" "two";
  let map name lines =
    let path = Filename.concat root name in
    Out_channel.with_open_bin path (fun oc ->
        List.iter (fun l -> output_string oc (l ^ "\n")) lines);
    path
  in
  let refused (module E : Engine.S) label m =
    match E.import ~map:m src with
      | _ -> p "%s: accepted\n" label
      | exception Fail.E { kind = Invalid; _ } -> p "%s: refused\n" label
  in
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~background:false ();
      B.start ~background:false ();
      ignore (A.resync ());
      ignore (B.resync ());
      p "== bad maps upload nothing\n";
      refused a "a duplicate domain path"
        (map "dup.map"
           ["x/one.txt\tArchives/a.txt"; "y/z/two.txt\tArchives/a.txt"]);
      refused a "a file holding another"
        (map "clash.map" ["x/one.txt\tArchives/a"; "y/z/two.txt\tArchives/a/b"]);
      refused a "three fields" (map "short.map" ["x/one.txt\tArchives/a\t1"]);
      refused a "a reserved path"
        (map "reserved.map" ["x/one.txt\t.tsync-ext/a"]);
      p "domain entries: %d\n" (List.length (tree a));
      p "\n== a map of two folders, one time override, one missing file\n";
      let mtime = 1015218367_123456700 and created = 1015000000_000000000 in
      report
        (A.import
           ~map:
             (map "good.map"
                [
                  Printf.sprintf "x/one.txt\tArchives/D/first.txt\t%d\t%d" mtime
                    created;
                  Filename.concat src "y/z/two.txt"
                  ^ "\t/Archives/D/deep/second.txt";
                  "gone.txt\tArchives/D/gone.txt";
                ])
           src);
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "B sees (override %d, %d):\n" mtime created;
      show b
        ~source_times:
          [
            ( "Archives/D/deep/second.txt",
              Fs.times (Filename.concat src "y/z/two.txt") );
          ];
      p "pending: A %d, B %d\n" (A.activity ()).pending (B.activity ()).pending);
  Test_support.finish root
