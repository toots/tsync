(* A rebuild sweeps nothing when local work happened during its walk
   (wal-and-journal §4.8). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-rebuild-race-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let during_walk : (unit -> unit) option Atomic.t = Atomic.make None

let once () =
  match Atomic.exchange during_walk None with Some f -> f () | None -> ()

let hooked (s : Store.t) =
  {
    s with
    list_prefix =
      (fun ?max_keys prefix ->
        once ();
        s.list_prefix ?max_keys prefix);
    list_many =
      Option.map
        (fun f prefixes ->
          once ();
          f prefixes)
        s.list_many;
  }

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

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client ~wrap:hooked "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      write b "kept.txt" "kept";
      B.mkdir "kept" ~exclusive:false;
      B.drain ~grace:10. ();
      pass a;
      A.set_paused true;
      Atomic.set during_walk (Some (fun () -> A.mkdir "late" ~exclusive:false));
      let full =
        match A.resync ~full:true () with
          | `Full (_, failures) -> Printf.sprintf "full, %d failures" failures
          | `Incremental _ -> "incremental"
      in
      p "rebuild with a mkdir during its walk: %s; hook ran: %b\n" full
        (Atomic.get during_walk = None);
      p "A: %s\n" (tree a);
      A.set_paused false;
      A.drain ~grace:10. ();
      pass a;
      pass b;
      p "after A drains\n  A: %s\n  B: %s\n" (tree a) (tree b);
      p "owed: A %d/%d\n" (A.pending_uploads ()) (A.pending_metadata ());
      Stop.request ());
  Fs.rm_rf root
