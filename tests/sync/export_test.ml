(* Export (spec 05 §4.4): a domain's files written to local directories from
   the store, with landing rules, resume after a cancel, and refusals. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-export-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

let client name : (module Engine.S) * (module Tsync_remote.Context.S) =
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
  end in
  ((module Engine.Make (C)), (module C : Tsync_remote.Context.S))

let drain (module E : Engine.S) = E.drain ~grace:10. ()

let report label (r : Export.report) =
  p "%s: exported %d (%d bytes), already there %d, failed %d%s\n" label
    r.exported r.bytes r.already_there (List.length r.failed)
    (if r.cancelled then ", cancelled" else "");
  List.iter
    (fun (d, why) -> p "  failed %s: %s\n" (Filename.basename d) why)
    r.failed;
  List.iter (fun d -> p "  pending %s\n" d) r.pending

let listing dir =
  let rec walk rel =
    let path = if rel = "" then dir else Filename.concat dir rel in
    if Sys.is_directory path then
      List.concat_map
        (fun n -> walk (if rel = "" then n else Filename.concat rel n))
        (List.sort compare (Array.to_list (Sys.readdir path)))
    else [Printf.sprintf "%s (%d)" rel (Unix.stat path).st_size]
  in
  if Sys.file_exists dir then String.concat "  " (walk "") else "(none)"

let () =
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  let file base rel body =
    let path = Filename.concat base rel in
    Fs.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc body)
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let big =
    Random.init 7;
    String.init 40000 (fun _ -> Char.chr (Random.int 256))
  in
  file src "top.txt" "top";
  file src "notes/a.txt" "alpha";
  file src "notes/deep/b.bin" big;
  Rt.run_sync (fun () ->
      let (module A), ctx = client "A" in
      let module X = Export.Make ((val ctx)) in
      A.start ~poll_journal:false ();
      ignore (A.import src);
      drain (module A);
      let cache_root = Filename.concat root "A/cache" in
      let export ?cancelled dst paths =
        match
          X.export ?cancelled ~cache_root ~dst:(Filename.concat root dst) paths
        with
          | r -> report dst r
          | exception Fail.E f ->
              p "%s: refused: %s\n" dst
                (Text.replace_all ~sub:(root ^ "/") ~by:"" f.reason)
      in
      p "== landing: the root, a file, a folder\n";
      export "all" [""];
      p "  %s\n" (listing (Filename.concat root "all"));
      export "one" ["notes/deep/b.bin"];
      p "  %s\n" (listing (Filename.concat root "one"));
      export "folder" ["notes/deep"];
      p "  %s\n" (listing (Filename.concat root "folder"));
      p "  content equal: %b\n"
        (read (Filename.concat root "all/notes/deep/b.bin") = big);
      p "\n== a rerun finds everything there\n";
      export "all" [""];
      p "\n== cancelled partway, then resumed\n";
      let checks = ref 0 in
      export "resumed" ["notes/deep/b.bin"] ~cancelled:(fun () ->
          incr checks;
          !checks > 3);
      export "resumed" ["notes/deep/b.bin"];
      p "  content equal: %b\n"
        (read (Filename.concat root "resumed/b.bin") = big);
      p "\n== changed upstream since an interrupted export: started over\n";
      let checks = ref 0 in
      export "changed" ["notes/a.txt"; "notes/deep/b.bin"] ~cancelled:(fun () ->
          incr checks;
          !checks > 3);
      file src "notes/deep/b.bin" (String.uppercase_ascii big);
      ignore (A.import ~only:["notes/deep/b.bin"] ~force_rehash:true src);
      drain (module A);
      export "changed" ["notes/a.txt"; "notes/deep/b.bin"];
      p "  content is the new one: %b\n"
        (read (Filename.concat root "changed/b.bin")
        = String.uppercase_ascii big);
      p "\n== refusals\n";
      export "missing" ["nowhere"];
      export "clash" ["notes/a.txt"; "notes/a.txt"];
      p "\n== unpublished edits are listed\n";
      A.set_paused true;
      A.create "notes/a.txt" ~exclusive:false;
      A.write "notes/a.txt" ~off:0 (Bigstring.of_string "edited");
      A.close "notes/a.txt";
      export "pending" ["notes"];
      p "  a.txt exported as published: %b\n"
        (read (Filename.concat root "pending/notes/a.txt") = "alpha");
      A.set_paused false;
      drain (module A));
  Fs.rm_rf root
