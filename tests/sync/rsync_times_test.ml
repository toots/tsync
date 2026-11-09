(* Rsync of the same bytes with other times (02 §2.6): the times are carried,
   into the domain and out of it. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-rsync-times-%d" (Unix.getpid ()))

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

let domain_times (module E : Engine.S) path = (E.stat path).times

let report label (r : Rsync_plan.report) =
  p "%s: copied %d, identical %d, failed %d\n" label r.copied r.identical
    (List.length r.failed)

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" and out = Filename.concat root "out" in
  Fs.mkdir_p src;
  Fs.mkdir_p out;
  let path = Filename.concat src "a.txt" in
  Out_channel.with_open_bin path (fun oc -> output_string oc "alpha");
  Rt.run_sync (fun () ->
      let a = client "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~background:false ();
      B.start ~background:false ();
      ignore (A.resync ());
      ignore (B.resync ());
      let local p = { Rsync_plan.side = Local; path = p }
      and domain = { Rsync_plan.side = Domain; path = "" } in
      report "into the domain" (A.rsync ~src:(local src) ~dst:domain ());
      A.drain ~grace:10. ();
      let written = 1_015_218_367_123_456_700 in
      Fs.set_times path { mtime = written; created = written };
      report "the same bytes, other times"
        (A.rsync ~src:(local src) ~dst:domain ());
      report "again" (A.rsync ~src:(local src) ~dst:domain ());
      A.drain ~grace:10. ();
      ignore (B.resync ());
      p "a peer holds the new mtime: %b\n"
        ((domain_times b "a.txt").mtime = written);
      p "a peer holds the source's creation time: %b\n"
        ((domain_times b "a.txt").created = (Fs.times path).created);
      report "out of the domain" (B.rsync ~src:domain ~dst:(local out) ());
      let copy = Filename.concat out "a.txt" in
      Fs.set_times copy { mtime = 0; created = 0 };
      report "a local copy with other times"
        (B.rsync ~src:domain ~dst:(local out) ());
      p "the local copy holds the domain's mtime: %b\n"
        ((Fs.times copy).mtime = written);
      p "the local copy holds the domain's creation time where one is set: %b\n"
        ((not Fs.sets_created)
        || (Fs.times copy).created = (domain_times b "a.txt").created);
      p "pending: A %d, B %d\n" (A.activity ()).pending (B.activity ()).pending);
  Test_support.finish root
