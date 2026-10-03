(* A peer's change applied under a folder this client moved (pitfall A-2.5):
   the anchor that says where the store files the folder is read in the
   read-ahead, never while the metadata lock is held. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-arrival-lock-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

(* Once [armed], each anchor read waits until the test lets it through. *)
let armed = Atomic.make false
let anchor_reads = Atomic.make 0
let let_through = Atomic.make 0

let watched (inner : Store.t) =
  {
    inner with
    get_opt =
      (fun key ->
        if
          Atomic.get armed
          && String.ends_with ~suffix:".tsync-parent" (Key.to_string key)
        then (
          let mine = Atomic.fetch_and_add anchor_reads 1 in
          while Atomic.get let_through <= mine do
            Rt.sleep 0.02
          done);
        inner.get_opt key);
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

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let pass (module E : Engine.S) =
  (match E.apply_pass () with
    | _ -> ()
    | exception e -> p "pass failed: %s" (Printexc.to_string e));
  match E.bridge () with
    | Engine.Hold _ -> ignore (E.resync ())
    | Incremental -> ()

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client ~wrap:watched "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      A.mkdir "papers" ~exclusive:false;
      write a "papers/one.txt" "one";
      A.drain ~grace:10. ();
      pass b;
      A.set_paused true;
      A.rename ~src:"papers" ~dst:"archive" ~exclusive:false;
      write b "papers/two.txt" "two";
      B.drain ~grace:10. ();
      Atomic.set armed true;
      let applied = Atomic.make false in
      Rt.spawn ~name:"pass" (fun () ->
          pass a;
          Atomic.set applied true);
      (* While each anchor read waits, a local namespace operation is tried:
         it completes unless the read holds the metadata lock. *)
      let rec drive ~under_lock =
        if Atomic.get applied then under_lock
        else if Atomic.get anchor_reads > Atomic.get let_through then (
          let name = Printf.sprintf "local-%d" (Atomic.get let_through) in
          let blocked =
            match
              Rt.with_timeout 1. (fun () -> A.mkdir name ~exclusive:false)
            with
              | () -> false
              | exception Rt.Timeout -> true
          in
          Atomic.incr let_through;
          drive ~under_lock:(if blocked then under_lock + 1 else under_lock))
        else (
          Rt.sleep 0.02;
          drive ~under_lock)
      in
      p "anchor reads made under the metadata lock: %d" (drive ~under_lock:0);
      Atomic.set armed false;
      p "the peer's file landed in the moved folder: %b"
        (A.kind "archive/two.txt" = `File));
  Fs.rm_rf root
