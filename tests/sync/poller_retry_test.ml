(* The journal poller survives a failed pass and reopens the publish gate
   (wal-and-journal §4.2 rule 9). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-poller-retry-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let journal_failures = Atomic.make 0

let flaky (s : Store.t) =
  {
    s with
    list_prefix =
      (fun ?max_keys prefix ->
        if
          String.starts_with
            ~prefix:(Key.prefix_to_string (Key.prefix "tsync/docs/journal/"))
            (Key.prefix_to_string prefix)
          && Atomic.get journal_failures > 0
        then (
          Atomic.decr journal_failures;
          Fail.raise_ Fail.Link "injected listing failure")
        else s.list_prefix ?max_keys prefix);
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

let names (module E : Engine.S) =
  List.map (fun (e : E.entry) -> e.name) (E.list_children "")

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let pass (module E : Engine.S) =
  ignore (E.apply_pass ());
  match E.bridge () with
    | Engine.Hold _ -> ignore (E.resync ())
    | Incremental -> ()

let rec until n f =
  if f () then true
  else if n = 0 then false
  else (
    Rt.sleep 0.1;
    until (n - 1) f)

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client "A" and b = client ~wrap:flaky "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      pass a;
      Atomic.set journal_failures 1;
      B.start ();
      write a "a.txt" "from A";
      A.drain ~grace:10. ();
      p "B applies A's file: %b\n"
        (until 100 (fun () -> List.mem "a.txt" (names b)));
      p "B's first listing failed: %b\n" (Atomic.get journal_failures = 0);
      write b "b.txt" "from B";
      B.drain ~grace:10. ();
      p "B publishes: %b\n"
        (until 50 (fun () ->
             pass a;
             List.mem "b.txt" (names a)));
      p "owed: B %d/%d\n" (B.pending_uploads ()) (B.pending_metadata ());
      Stop.request ());
  Fs.rm_rf root
