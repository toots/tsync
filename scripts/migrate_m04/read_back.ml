(* A re-import that finds a file's time changed and its bytes the same
   publishes the time (conflict-resolution §2). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let root = "/var/tmp/claude-m04-fixture"
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

let walk (module E : Engine.S) =
  let rec go dir =
    List.iter
      (fun (e : E.entry) ->
        let p = Names.join dir e.name in
        if e.is_dir then (
          Printf.printf "%s/\n" p;
          go p)
        else (
          let h = E.open_read p in
          let content =
            Fun.protect
              ~finally:(fun () -> E.close_read h)
              (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:1000))
          in
          Printf.printf "%s size=%d mtime=%d created=%d %S\n" p e.st.size
            e.st.times.mtime e.st.times.created content))
      (E.list_children dir)
  in
  go ""

let () =
  Rt.run_sync (fun () ->
      let c = client "C" in
      let (module C) = c in
      C.start ~background:false ();
      ignore (C.resync ());
      walk c;
      C.revert "a.txt";
      C.drain ~grace:10. ();
      print_endline "-- after reverting a.txt to its saved version";
      walk c)
