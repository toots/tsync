(* A folder of many folders (02 §4.5, data-model §6.2): its listing reads the
   children's anchors in batches, not one round trip each. *)

open Tsync_core
open Tsync_store
open Tsync_remote

let d = Domain_name.v "d"
let folders = 3000

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-wide-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let inner = Local.create ~name:"main" (Filename.concat root "main") in
  let singles = Atomic.make 0 and batches = Atomic.make 0 in
  let counted =
    {
      inner with
      get_opt =
        (fun k ->
          Atomic.incr singles;
          inner.get_opt k);
      get_many =
        Some
          (fun keys ->
            Atomic.incr batches;
            List.map inner.get_opt keys);
    }
  in
  let composite =
    Composite.create ~domain:d
      ~data_dir:(Filename.concat root "data")
      ~owner:true ~poke:ignore
      ~knowledge:
        { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }
      [{ name = "main"; role = Main; store = counted }]
  in
  let module T = Tree.Make (struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = None
    let max_downloads = 1
    let max_chunk_buffers = 4
  end) in
  Rt.run_sync (fun () ->
      for i = 0 to folders - 1 do
        let name = Printf.sprintf "d%04d" i in
        let id = Folder_id.mint ~uuid:(String.make 32 'a') ~counter:(i + 1) in
        inner.put
          (Key.child d Folder_id.root name)
          (Bigstring.of_string (Folder.marker_body { name; id }));
        inner.put (Key.anchor d id)
          (Bigstring.of_string
             (Folder.anchor_body { parent = Folder_id.root; aname = name }))
      done;
      let n = List.length (T.children Folder_id.root) in
      Printf.printf "%d folders listed: %d single reads, %d batches\n" n
        (Atomic.get singles) (Atomic.get batches));
  Fs.rm_rf root
