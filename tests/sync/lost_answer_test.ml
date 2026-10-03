(* A store change whose answer is lost, retried: the entry is still published
   and nothing parks (wal-and-journal §4.7). *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-lost-answer-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

(* The next call of the armed kind on a matching key fails: a "put" or "copy"
   after it is made, a "refused put" or "refused delete" before. *)
let armed : (string * (Key.t -> bool)) option Atomic.t = Atomic.make None

let lose kind key =
  match Atomic.get armed with
    | Some (k, matches) when k = kind && matches key ->
        Atomic.set armed None;
        Fail.raise_ Fail.Link "answer lost: %s %s" kind (Key.to_string key)
    | _ -> ()

let lossy (s : Store.t) =
  {
    s with
    put =
      (fun ?mode key body ->
        lose "refused put" key;
        s.put ?mode key body;
        lose "put" key);
    delete =
      (fun key ->
        lose "refused delete" key;
        s.delete key);
    copy =
      (fun src dst ->
        s.copy src dst;
        lose "copy" dst);
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

module Str_index = struct
  let find s sub =
    let n = String.length sub in
    let rec go i =
      if i + n > String.length s then None
      else if String.sub s i n = sub then Some i
      else go (i + 1)
    in
    go 0
end

let under prefix key = String.starts_with ~prefix (Key.to_string key)

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let a = client ~wrap:lossy "A" and b = client "B" in
      let (module A) = a and (module B) = b in
      A.start ~poll_journal:false ();
      B.start ~poll_journal:false ();
      pass a;
      pass b;
      let step label kind matches f =
        Atomic.set armed (Some (kind, matches));
        f ();
        A.drain ~grace:10. ();
        pass a;
        A.drain ~grace:10. ();
        pass b;
        p "== %s\n  failed once: %b; B: %s; A parked %d, owed %d\n" label
          (Atomic.get armed = None)
          (tree b)
          (List.length (A.parked ()))
          (A.pending_metadata ())
      in
      A.mkdir "d1" ~exclusive:false;
      A.mkdir "d2" ~exclusive:false;
      A.mkdir "x" ~exclusive:false;
      write a "f.txt" "file";
      A.drain ~grace:10. ();
      pass b;
      p "B: %s\n" (tree b);
      step "rmdir, the journal entry refused" "refused put"
        (under "tsync/docs/journal/") (fun () -> A.rmdir "d1");
      step "rmdir, the anchor's answer lost" "put"
        (fun k -> String.ends_with ~suffix:".tsync-parent" (Key.to_string k))
        (fun () -> A.rmdir "d2");
      step "file rename, the copy's answer lost" "copy"
        (fun _ -> true)
        (fun () -> A.rename ~src:"f.txt" ~dst:"g.txt" ~exclusive:false);
      step "folder rename, the old marker's delete refused" "refused delete"
        (fun k ->
          Key.to_string k = Key.to_string (Key.child d Folder_id.root "x"))
        (fun () -> A.rename ~src:"x" ~dst:"y" ~exclusive:false);
      let store = Local.create ~name:"main" (Filename.concat root "store") in
      let slot name = Key.child d Folder_id.root name in
      p "  old marker left: %b\n" (store.get_opt (slot "x") <> None);
      let rebuild label =
        p "a full rebuild of B %s: %s\n" label
          (match B.resync ~full:true () with
            | `Full (_, failures) -> Printf.sprintf "%d failures" failures
            | `Incremental _ -> "incremental")
      in
      rebuild "after the rename";
      let marker =
        Bigstring.to_string (Option.get (store.get_opt (slot "y")))
      in
      let at = Option.get (Str_index.find marker {|"name":"y"|}) in
      store.put (slot "x")
        (Bigstring.of_string
           (String.sub marker 0 at ^ {|"name":"x"|}
           ^ String.sub marker (at + 10) (String.length marker - at - 10)));
      rebuild "with a disowned marker";
      p "B: %s\n" (tree b);
      Stop.request ());
  Fs.rm_rf root
