(* Journal entries from an older writer name no folder id: readers resolve it
   from the store's marker and keep going (wal-and-journal §3.2). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-legacy-entry-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let client ?(wrap = Fun.id) name : (module Engine.S) =
  let data_dir = Filename.concat root (name ^ "/data") in
  let store = wrap (Local.create ~name:"main" (Filename.concat root "store")) in
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
        if e.is_dir then (p ^ "/") :: walk p else [p])
      (E.list_children path)
  in
  String.concat " " (walk "")

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let pass (module E : Engine.S) =
  ignore (E.apply_pass ());
  match E.bridge () with
    | Engine.Hold _ -> ignore (E.resync ())
    | Incremental -> ()

let rec files dir =
  List.concat_map
    (fun n ->
      let path = Filename.concat dir n in
      if Sys.is_directory path then files path else [path])
    (Option.value ~default:[] (Fs.readdir_opt dir))

let find s sub from =
  let n = String.length sub in
  let rec go i =
    if i + n > String.length s then None
    else if String.sub s i n = sub then Some i
    else go (i + 1)
  in
  go from

(* Drop the folder id from every entry holding the given op. *)
let strip_ids op =
  let n = ref 0 in
  List.iter
    (fun f ->
      let body = Fs.read_file f in
      if find body (Printf.sprintf {|"op":"%s"|} op) 0 <> None then (
        match find body {|,"id":"|} 0 with
          | Some i ->
              incr n;
              let close = Option.get (find body {|"|} (i + 7)) in
              Fs.write_file_for_test f
                (String.sub body 0 i
                ^ String.sub body (close + 1) (String.length body - close - 1))
          | None -> ()))
    (files (Filename.concat root "store/tsync/docs/journal"));
  p "ids stripped from %s entries: %d\n" op !n

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      A.mkdir "x" ~exclusive:false;
      A.drain ~grace:10. ();
      strip_ids "mkdir";
      write a "x/f.txt" "inside";
      A.drain ~grace:10. ();
      pass b;
      p "after an id-less mkdir\n  B: %s\n" (tree b);
      A.rename ~src:"x" ~dst:"y" ~exclusive:false;
      A.drain ~grace:10. ();
      strip_ids "rename";
      write a "after.txt" "later";
      A.drain ~grace:10. ();
      pass b;
      p "after an id-less folder rename\n  B: %s\n" (tree b);
      Stop.request ());
  Fs.rm_rf root
