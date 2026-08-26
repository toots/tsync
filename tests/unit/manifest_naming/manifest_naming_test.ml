(* What a manifest is called, and where that answer comes from.

   A manifest is filed under a key and the key's leaf is its name. The body
   carries a name too, but only because two locations cannot express one: a
   backend key is [<folder-id>/<hash>], and a cache leaf whose real name is not
   filesystem-safe is [.tsync-esc-<hash>]. Both are one-way.

   So the rule is: ask the location, fall back to the body only where the
   location cannot say. What is pinned here is that a rename cannot separate the
   two — the case that made every listing show a file's previous name and none
   show its current one, while opening the previous name gave ENOENT. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "manifest-naming"
let domain = "testdom"

module Store =
  (val Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module C =
  (val Fixture.conf ~domain
         ~chunk_size:(8 * 1024 * 1024)
         ~cache_chunk_size:(8 * 1024 * 1024)
         ~store:(module Store : Backend.S)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Lk = Logical_key.Make (C)
module Mf = Manifests_lwt.Make (C)
module Ck = Checkout.Make (C)
module Mfs = Staged_lwt.Manifest.Make (C)

let key rel = Lk.file @@ rel

(* Digests are fixed-width hex; the values are arbitrary but must be well
   formed or the encoder rejects them. *)
let body ~name =
  Manifest_fixture.make ~name ~h1:"1111111111111111" ~h2:"2222222222222222"
    ~size:4L ~chunk_size:64
    ~chunks:
      [
        Manifest.
          {
            index = 0;
            h1 = "3333333333333333";
            h2 = "4444444444444444";
            size = 4;
          };
      ]
    ~mtime:0.

(* What a listing would show for [rel], and what the body says on its own. Equal
   for an ordinary name; only the second is available for an escaped one. *)
(* The rule under test, spelled here rather than called: ask the location, and
   consult the body only for an escaped on-disk leaf, which is the one case a
   path cannot express. *)
let name_of ~key m =
  let leaf = Logical_key.leaf key in
  if Stored_key.is_escaped leaf then Manifest.recorded_name m else leaf

let report rel =
  let k = key rel in
  let+ m = Mf.published k in
  match m with
    | None -> step "%s: absent" rel
    | Some m ->
        step "%s -> name_of=%S recorded=%S" rel (name_of ~key:k m)
          (Manifest.recorded_name m)

(* Directory names as a listing shows them, which is where an escaped name is
   resolved back through its marker. *)
let list_dirs () =
  let+ _files, dirs = Ck.list_children ~prefix:Lk.root () in
  String.concat ", " (List.sort compare dirs)

let () =
  Lwt_main.run
    (case "written under a key";
     (* The caller hands over a body that names something else entirely; the
        writer stamps the key's leaf regardless, which is what makes the
        invariant hold rather than merely usually hold. *)
     let* () = Mf.write (key "a/b.txt") (body ~name:"something-else") in
     let* () = report "a/b.txt" in

     case "renamed";
     (* The case that was broken: the body travels with the file, so anything
        reading the body alone would still answer [b.txt]. *)
     let* () = Ck.rename ~src_key:(key "a/b.txt") ~dst_key:(key "a/c.txt") in
     let* () = report "a/c.txt" in
     let* () = report "a/b.txt" in

     case "a name the filesystem cannot hold";
     (* ":" is escaped even where the local filesystem would accept it, so the
        on-disk leaf is a hash and the body is the only way back. *)
     let odd = "we:ird.txt" in
     let* () = Mf.write (key odd) (body ~name:"ignored") in
     let* () = report odd in
     let escaped_on_disk =
       Stored_key.is_escaped (Filename.basename (Mf.path (key odd)))
     in
     step "on-disk leaf is escaped: %b" escaped_on_disk;

     case "renamed to an ordinary name";
     let* () = Ck.rename ~src_key:(key odd) ~dst_key:(key "plain.txt") in
     let* () = report "plain.txt" in

     case "a directory whose name the filesystem cannot hold";
     (* A directory keeps its real name in a [.tsync-name] marker beside it, for
        the same reason a manifest keeps one in its body: the escaped on-disk
        name is a hash. Renaming has to move the marker's contents too, or the
        directory goes on presenting its previous name. *)
     let* () = Ck.create_dir (key "di:r/") in
     let* dirs = list_dirs () in
     step "before: %s" dirs;
     let* () = Ck.rename ~src_key:(key "di:r/") ~dst_key:(key "ot:her/") in
     let* dirs = list_dirs () in
     step "after renaming di:r -> ot:her: %s" dirs;

     case "staged, then renamed";
     let staged =
       Staged_manifest.
         {
           s_name = "whatever";
           s_size = 0L;
           s_mtime = 0.;
           s_chunk_size = 64;
           s_slots = [||];
           s_whole = None;
         }
     in
     let* () = Mfs.write (key "s/one.txt") staged in
     let* st = Mfs.read_edits (key "s/one.txt") in
     step "s/one.txt staged name=%S"
       (match st with
         | Some st -> st.Staged_manifest.s_name
         | None -> "<absent>");
     let* () =
       Mfs.rename ~src_key:(key "s/one.txt") ~dst_key:(key "s/two.txt")
     in
     let+ st = Mfs.read_edits (key "s/two.txt") in
     step "s/two.txt staged name=%S"
       (match st with
         | Some st -> st.Staged_manifest.s_name
         | None -> "<absent>"));
  Lwt_main.run (Io_lwt.Fs.rm_rf root)
