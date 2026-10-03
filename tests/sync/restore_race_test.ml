(* A trash restore whose name is taken here while the store answers
   (pitfall A-2.1): the unpublished item steps aside, and the folder comes back
   at its name. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-restore-race-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

(* Runs once, inside the next write to the store. *)
let during_next_put : (unit -> unit) option Atomic.t = Atomic.make None

let watched (inner : Store.t) =
  let fire () =
    match Atomic.exchange during_next_put None with
      | Some f -> f ()
      | None -> ()
  in
  {
    inner with
    put =
      (fun ?mode key body ->
        fire ();
        inner.put ?mode key body);
    put_if_absent =
      (fun key body ->
        fire ();
        inner.put_if_absent key body);
  }

let client : (module Engine.S) =
  let data_dir = Filename.concat root "A/data" in
  let store =
    watched (Local.create ~name:"main" (Filename.concat root "store"))
  in
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
    let cache_root = Filename.concat root "A/cache"
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = "A"
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  (module Engine.Make (C))

module A = (val client)

let write path content =
  A.create path ~exclusive:false;
  A.write path ~off:0 (Bigstring.of_string content);
  A.close path

let rec tree path =
  List.concat_map
    (fun (e : A.entry) ->
      let p = Names.join path e.name in
      if e.is_dir then (p ^ "/") :: tree p else [p])
    (A.list_children path)

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      A.start ~poll_journal:false ();
      ignore (A.resync ());
      A.mkdir "box" ~exclusive:false;
      write "box/a.txt" "first";
      A.drain ~grace:10. ();
      A.delete "box/a.txt";
      A.rmdir "box";
      A.drain ~grace:10. ();
      A.set_paused true;
      Atomic.set during_next_put (Some (fun () -> write "box" "a file"));
      p "restore: %s"
        (match A.restore_from_trash "box" with
          | `Restored n -> Printf.sprintf "%d announced" n
          | `Not_in_trash -> "not in the trash"
          | `Exists -> "name taken"
          | exception e -> "failed: " ^ Printexc.to_string e);
      p "the name was taken meanwhile: %b" (Atomic.get during_next_put = None);
      p "tree: %s" (String.concat "  " (tree ""));
      A.set_paused false;
      A.drain ~grace:10. ();
      p "owed after draining: %d uploads, %d metadata, %d parked"
        (A.pending_uploads ()) (A.pending_metadata ())
        (List.length (A.parked ())));
  Fs.rm_rf root
