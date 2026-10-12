(* Every row of conflict-resolution §8.3 on two clients and one main: B's
   change is pending when A's entry arrives. Each row ends with the trees of
   A, of B and of a third client that arrives by state, compared with file
   contents (INV-rows, INV-converge, INV-quiet). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let base =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-rows-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let client root name : (module Engine.S) =
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
    let versioning = false
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
    let tuning () = Tuning.default
  end in
  (module Engine.Make (C))

let tree (module E : Engine.S) =
  let rec walk path =
    List.concat_map
      (fun (e : E.entry) ->
        let p = Names.join path e.name in
        if e.is_dir then (p ^ "/") :: walk p
        else (
          let h = E.open_read p in
          let content =
            Fun.protect
              ~finally:(fun () -> E.close_read h)
              (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:1000))
          in
          [Printf.sprintf "%s=%S" p content]))
      (E.list_children path)
  in
  walk ""

type ops = {
  write : string -> string -> unit;
  delete : string -> unit;
  mv : string -> string -> unit;
  mkdir : string -> unit;
  rmdir : string -> unit;
}

let ops (module E : Engine.S) =
  {
    write =
      (fun path content ->
        E.create path ~exclusive:false;
        E.write path ~off:0 (Bigstring.of_string content);
        E.close path);
    delete = E.delete;
    mv = (fun src dst -> E.rename ~src ~dst ~exclusive:false);
    mkdir = (fun path -> E.mkdir path ~exclusive:false);
    rmdir = E.rmdir;
  }

let settle (module E : Engine.S) =
  try E.drain ~grace:10. ()
  with e -> p "  drain failed: %s\n" (Printexc.to_string e)

let sync (module E : Engine.S) =
  match E.resync () with
    | _ -> ()
    | exception e -> p "  sync failed: %s\n" (Printexc.to_string e)

let rows = ref 0
and diverged = ref 0

let row name ~setup ~b ~a =
  incr rows;
  let root = Filename.concat base name in
  let ca = client root "A" and cb = client root "B" in
  let (module A) = ca and (module B) = cb in
  A.start ~background:false ();
  B.start ~background:false ();
  sync ca;
  sync cb;
  setup (ops ca);
  settle ca;
  sync cb;
  b (ops cb);
  a (ops ca);
  settle ca;
  settle cb;
  sync ca;
  sync cb;
  sync ca;
  let cc = client root "C" in
  let (module C) = cc in
  C.start ~background:false ();
  sync cc;
  let ta = tree ca and tb = tree cb and tc = tree cc in
  let quiet =
    (A.activity ()).pending = 0
    && (B.activity ()).pending = 0
    && A.pending_uploads () = 0
    && B.pending_uploads () = 0
  in
  p "%s: %s\n" name (String.concat "  " ta);
  if ta <> tb || ta <> tc then (
    incr diverged;
    p "  DIVERGED\n  B: %s\n  main: %s\n" (String.concat "  " tb)
      (String.concat "  " tc));
  if not quiet then (
    incr diverged;
    p "  NOT QUIET: A pending %d, B pending %d\n" (A.activity ()).pending
      (B.activity ()).pending)

let nothing _ = ()

let () =
  Fs.rm_rf base;
  Rt.run_sync (fun () ->
      let f o = o.write "f" "base" in
      let dir o = o.mkdir "d" in
      row "N1" ~setup:f
        ~b:(fun o ->
          o.delete "f";
          o.write "f" "B")
        ~a:nothing;
      row "N2"
        ~setup:(fun o ->
          o.write "f" "f";
          o.write "g" "g")
        ~b:(fun o -> o.mv "f" "g")
        ~a:nothing;
      row "F1" ~setup:f ~b:(fun o -> o.delete "f") ~a:(fun o -> o.write "f" "A");
      row "F2" ~setup:f ~b:(fun o -> o.delete "f") ~a:(fun o -> o.mv "f" "h");
      row "F3" ~setup:f
        ~b:(fun o -> o.delete "f")
        ~a:(fun o ->
          o.write "x" "A";
          o.mv "x" "f");
      row "F4" ~setup:f ~b:(fun o -> o.mv "f" "g") ~a:(fun o -> o.write "f" "A");
      row "F5" ~setup:f ~b:(fun o -> o.mv "f" "g") ~a:(fun o -> o.delete "f");
      row "F6" ~setup:f ~b:(fun o -> o.mv "f" "g") ~a:(fun o -> o.mv "f" "h");
      row "F7" ~setup:f ~b:(fun o -> o.mv "f" "g") ~a:(fun o -> o.write "g" "A");
      row "F8" ~setup:f
        ~b:(fun o -> o.mv "f" "g")
        ~a:(fun o ->
          o.write "g" "A";
          o.mv "g" "h");
      row "F9" ~setup:f
        ~b:(fun o -> o.write "f" "B")
        ~a:(fun o -> o.write "f" "A");
      row "F10" ~setup:f
        ~b:(fun o -> o.write "f" "B")
        ~a:(fun o -> o.mv "f" "g");
      row "F11" ~setup:f
        ~b:(fun o -> o.write "g" "B")
        ~a:(fun o -> o.mv "f" "g");
      row "F12" ~setup:f
        ~b:(fun o -> o.write "f" "B")
        ~a:(fun o -> o.delete "f");
      row "F13"
        ~setup:(fun o ->
          o.write "x" "x";
          o.write "f" "base")
        ~b:(fun o -> o.mv "x" "f")
        ~a:(fun o -> o.delete "f");
      row "F14"
        ~setup:(fun o ->
          o.write "x" "x";
          o.write "f" "base")
        ~b:(fun o -> o.mv "x" "g")
        ~a:(fun o -> o.mv "f" "g");
      row "F15" ~setup:f
        ~b:(fun o -> o.write "f" "same")
        ~a:(fun o -> o.write "f" "same");
      row "D1"
        ~setup:(fun o ->
          o.mkdir "d";
          o.write "d/a" "a")
        ~b:(fun o ->
          o.delete "d/a";
          o.rmdir "d")
        ~a:(fun o -> o.write "d/x" "x");
      row "D2" ~setup:dir ~b:(fun o -> o.rmdir "d") ~a:(fun o -> o.mv "d" "e");
      row "D3" ~setup:dir
        ~b:(fun o -> o.mv "d" "e")
        ~a:(fun o -> o.write "d/x" "x");
      row "D4" ~setup:dir ~b:(fun o -> o.mv "d" "e") ~a:(fun o -> o.mv "d" "f");
      row "D5" ~setup:dir
        ~b:(fun o ->
          o.mv "d" "e";
          o.write "e/ours" "ours")
        ~a:(fun o ->
          o.mkdir "e";
          o.write "e/theirs" "theirs");
      row "D6" ~setup:nothing
        ~b:(fun o ->
          o.mkdir "d";
          o.write "d/ours" "ours")
        ~a:(fun o ->
          o.mkdir "d";
          o.write "d/theirs" "theirs");
      row "D7" ~setup:dir ~b:(fun o -> o.rmdir "d") ~a:(fun o -> o.rmdir "d");
      row "D8" ~setup:dir
        ~b:(fun o ->
          o.write "d/new" "new";
          o.mkdir "d/sub";
          o.write "d/sub/new" "new")
        ~a:(fun o -> o.rmdir "d");
      row "D9" ~setup:dir
        ~b:(fun o -> o.write "d/x" "x")
        ~a:(fun o -> o.mv "d" "e");
      row "D10"
        ~setup:(fun o ->
          o.mkdir "d";
          o.mkdir "e")
        ~b:(fun o -> o.mv "d" "e/d")
        ~a:(fun o -> o.mv "e" "d/e");
      row "D11"
        ~setup:(fun o ->
          o.mkdir "d";
          o.write "d/in-d" "d";
          o.mkdir "e";
          o.write "e/in-e" "e")
        ~b:(fun o ->
          o.mv "d" "t";
          o.mv "e" "d";
          o.mv "t" "e")
        ~a:nothing;
      row "K1" ~setup:nothing
        ~b:(fun o -> o.write "x" "file")
        ~a:(fun o ->
          o.mkdir "x";
          o.write "x/in" "in");
      row "K2" ~setup:nothing
        ~b:(fun o ->
          o.mkdir "x";
          o.write "x/in" "in")
        ~a:(fun o -> o.write "x" "file"));
  p "%d rows, %d diverged or not quiet\n" !rows !diverged;
  Test_support.finish base
