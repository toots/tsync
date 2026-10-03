(* rebuild_mem STORE_ROOT DOMAIN: a full rebuild from a local store into fresh
   local state, sampling private memory throughout. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let mib n = float_of_int n /. 1048576.

let () =
  let root = Sys.argv.(1) and d = Domain_name.v Sys.argv.(2) in
  (* Not /tmp: a rebuild's mirror can be gigabytes, and /tmp is a small tmpfs. *)
  let scratch =
    Filename.concat
      (Option.value
         ~default:(Filename.concat (Sys.getenv "HOME") "tsync-bench")
         (Sys.getenv_opt "TSYNC_BENCH_DIR"))
      (Printf.sprintf "rebuild-mem-%d" (Unix.getpid ()))
  in
  Fs.rm_rf scratch;
  let data_dir = Filename.concat scratch "data" in
  let store = Local.create ~name:"main" root in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore
      ~knowledge:
        { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }
      [{ name = "main"; role = Main; store }]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = false
    let chunk_size_config = None
    let max_downloads = 8
    let max_chunk_buffers = 4
    let cache_root = Filename.concat scratch "cache"
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = "bench"
    let cache_chunk_size = Tsync_checkout.Cache.default_cache_chunk_size
    let max_cache = None
    let max_uploads = 1
    let read_only = true
    let symlinks = `Keep
    let lazy_tree = false
  end in
  let module E = Engine.Make (C) in
  let show label (u : Usage.t) =
    let o = function Some n -> Printf.sprintf "%.0f" (mib n) | None -> "?" in
    Printf.printf
      "%-20s private %5.0f MiB  anonymous %5s  mapped files %5s  heap %5.0f \
       (top %5.0f)  majors %d\n\
       %!"
      label (mib u.private_) (o u.anonymous) (o u.file_backed) (mib u.heap)
      (mib u.top_heap) u.major_collections
  in
  Rt.run_sync (fun () ->
      let start = Usage.sample () in
      let peak = Atomic.make start in
      let stop = Atomic.make false in
      Rt.spawn (fun () ->
          while not (Atomic.get stop) do
            let u = Usage.sample () in
            if u.private_ > (Atomic.get peak).private_ then Atomic.set peak u;
            Rt.sleep 0.2
          done);
      let t0 = Unix.gettimeofday () in
      let manifests, failures = E.rebuild () in
      Atomic.set stop true;
      Printf.printf "%d manifests, %d failures, %.0fs\n" manifests failures
        (Unix.gettimeofday () -. t0);
      show "start" start;
      show "peak (private)" (Atomic.get peak);
      show "after" (Usage.sample ());
      Gc.full_major ();
      Gc.compact ();
      show "after compaction" (Usage.sample ());
      Usage.trim ();
      show "after malloc trim" (Usage.sample ()));
  Fs.rm_rf scratch
