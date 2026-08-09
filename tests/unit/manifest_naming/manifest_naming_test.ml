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

let root = Filename.temp_dir "tsync-manifest-naming" ""
let domain = "testdom"
let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")
let case name = Printf.printf "\n=== %s\n" name

module Store = (val Local_backend.make ~root:(Filename.concat root "store"))

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = domain
  let domain_prefix = "tsync/" ^ domain ^ "/manifests/"
  let chunk_prefix = "tsync/" ^ domain ^ "/chunks/"
  let versions_prefix = "tsync/" ^ domain ^ "/versions/"
  let journal_prefix = "tsync/" ^ domain ^ "/journal/"
  let cursor_key = "tsync/" ^ domain ^ "/cursor"
  let shares_prefix = "tsync/shares/"
  let store = (module Store : Backend.S)
  let members = [Backend.member ~name:"local" store]
  let cache_root = root
  let data_dir = root
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some (8 * 1024 * 1024)
  let cache_chunk_size = Some (8 * 1024 * 1024)
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Mf = Manifest.Make (C)

let key rel = C.domain_prefix ^ rel

(* Digests are fixed-width hex; the values are arbitrary but must be well
   formed or the encoder rejects them. *)
let body ~name =
  Manifest.make ~name ~h1:"1111111111111111" ~h2:"2222222222222222" ~size:4L
    ~chunk_size:64
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
  let leaf = Key.leaf ~domain_prefix:C.domain_prefix key in
  if Name_escape.is_escaped leaf then Manifest.recorded_name m else leaf

let report rel =
  let k = key rel in
  let+ m = Mf.read k in
  match m with
    | None -> step "%s: absent" rel
    | Some m ->
        step "%s -> name_of=%S recorded=%S" rel (name_of ~key:k m)
          (Manifest.recorded_name m)

(* Directory names as a listing shows them, which is where an escaped name is
   resolved back through its marker. *)
let list_dirs () =
  let+ _files, dirs = Mf.list_children ~prefix:C.domain_prefix () in
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
     let* () = Mf.rename ~src_key:(key "a/b.txt") ~dst_key:(key "a/c.txt") in
     let* () = report "a/c.txt" in
     let* () = report "a/b.txt" in

     case "a name the filesystem cannot hold";
     (* ":" is escaped even where the local filesystem would accept it, so the
        on-disk leaf is a hash and the body is the only way back. *)
     let odd = "we:ird.txt" in
     let* () = Mf.write (key odd) (body ~name:"ignored") in
     let* () = report odd in
     let escaped_on_disk =
       Name_escape.is_escaped (Filename.basename (Mf.path (key odd)))
     in
     step "on-disk leaf is escaped: %b" escaped_on_disk;

     case "renamed to an ordinary name";
     let* () = Mf.rename ~src_key:(key odd) ~dst_key:(key "plain.txt") in
     let* () = report "plain.txt" in

     case "a directory whose name the filesystem cannot hold";
     (* A directory keeps its real name in a [.tsync-name] marker beside it, for
        the same reason a manifest keeps one in its body: the escaped on-disk
        name is a hash. Renaming has to move the marker's contents too, or the
        directory goes on presenting its previous name. *)
     let* () = Mf.create_dir (key "di:r/") in
     let* dirs = list_dirs () in
     step "before: %s" dirs;
     let* () = Mf.rename ~src_key:(key "di:r/") ~dst_key:(key "ot:her/") in
     let* dirs = list_dirs () in
     step "after renaming di:r -> ot:her: %s" dirs;

     case "staged, then renamed";
     let staged =
       Manifest.
         {
           s_name = "whatever";
           s_size = 0L;
           s_mtime = 0.;
           s_chunk_size = 64;
           s_slots = [||];
           s_whole = None;
           s_published = None;
         }
     in
     let* () = Mf.write_staged (key "s/one.txt") staged in
     let* st = Mf.read_staged (key "s/one.txt") in
     step "s/one.txt staged name=%S"
       (match st with Some st -> st.Manifest.s_name | None -> "<absent>");
     let* () =
       Mf.rename_staged ~src_key:(key "s/one.txt") ~dst_key:(key "s/two.txt")
     in
     let+ st = Mf.read_staged (key "s/two.txt") in
     step "s/two.txt staged name=%S"
       (match st with Some st -> st.Manifest.s_name | None -> "<absent>"));
  Lwt_main.run (Fs_util.rm_rf root)
