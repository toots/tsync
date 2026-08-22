(* A write in flight is a file staged under a name of its own, waiting for the
   rename that makes it an object. Nothing outside the backend may see it: the
   key is gone by the time anybody asks for it, and its body is whatever part of
   the write has landed so far.

   The mirror is where that hurts. Listing one copies a partial body to every
   other backend under a name no manifest refers to, and no later collection
   meets it again -- the copy is left holding it for good.

   The pid in a staged name varies per run, so it is masked before printing. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "writes-in-flight"
let src_dir = Scratch.sub root "src"
let dst_dir = Scratch.sub root "dst"
let domain_prefix = "tsync/d/manifests/"
let chunk_prefix = "tsync/d/chunks/"
let shard = "2e2/"

module Local =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some src_dir) ()
      : Backend.S)

module Dst =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some dst_dir) ()
      : Backend.S)

(* The staged file is planted on disk rather than caught mid-write: what is
   under test is the listing, and a real race would not reproduce. *)
let staged_name = Filename.basename (Fs_util.temp_path "x")
let staged_path = String.concat "/" [src_dir; chunk_prefix ^ shard; staged_name]
let staged_key = chunk_prefix ^ shard ^ staged_name

(* A store that hands out the staged name anyway: an older tsync copied one here
   before its listings hid them, and that copy is now an object like any other.
   Reached through the same listing the mirror uses, so the mirror's own guard
   is what has to refuse it. *)
module Stale = struct
  include Local

  let list_prefix ?max_keys ~prefix () =
    let* entries = Local.list_prefix ?max_keys ~prefix () in
    if String.starts_with ~prefix staged_key then
      let+ head = Local.head_opt ~key:staged_key () in
      match head with Some e -> entries @ [e] | None -> entries
    else Lwt.return entries
end

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "d"
  let domain_prefix = domain_prefix
  let chunk_prefix = chunk_prefix
  let versions_prefix = "tsync/d/versions/"
  let journal_prefix = "tsync/d/journal/"
  let cursor_key = "tsync/d/cursor"
  let shares_prefix = "tsync/shares/"

  let members =
    [
      Backend.member ~role:"main" ~backend_type:"local" ~local_path:src_dir
        ~name:"source"
        (module Stale);
      Backend.member ~role:"replica" ~backend_type:"local" ~local_path:dst_dir
        ~name:"copy"
        (module Dst);
    ]

  let store =
    Domain_store.make
      ~mains:[{ Domain_store.name = "source"; backend = (module Stale) }]
      ~targets:[]
      ~archives:[{ Domain_store.name = "copy"; backend = (module Dst) }]

  let cache_root = Scratch.sub root "cache"
  let data_dir = Scratch.sub root "data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 2
  let max_downloads = 1
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module M = Mirror.Make (C)

let mask key =
  let name = Filename.basename key in
  if Fs_util.is_temp_name name then
    Filename.concat (Filename.dirname key) ".tsync-tmp-<staged>.tmp"
  else key

let show label keys =
  Printf.printf "  %s\n" label;
  match keys with
    | [] -> print_endline "    (nothing)"
    | keys -> List.iter (fun k -> Printf.printf "    %s\n" (mask k)) keys

let keys_under dir =
  let rec walk dir =
    Sys.readdir dir |> Array.to_list |> List.sort compare
    |> List.concat_map (fun e ->
        let p = Filename.concat dir e in
        if Sys.is_directory p then walk p else [p])
  in
  if Sys.file_exists dir then
    List.map
      (fun p ->
        String.sub p
          (String.length dir + 1)
          (String.length p - String.length dir - 1))
      (walk dir)
  else []

(* Named from its own body: a chunk read back under a name it does not hash to
   is filed as corrupt, which is a different test. *)
let body = Bigstring.of_string "chunk body"
let chunk_key = chunk_prefix ^ shard ^ Chunk_layout.key_of_body body

let () =
  Lwt_main.run
    (let* () = Local.put ~key:chunk_key ~data:body () in
     (* A user's own file whose name merely ends in ".tmp": it is an object, and
        hiding it would be the mirror deciding what a user may store. *)
     let user_key =
       chunk_prefix ^ shard ^ ".syncthing.Big.Buck.Bunny.mkv.tmp"
     in
     let* () =
       Local.put ~key:user_key ~data:(Bigstring.of_string "in flight") ()
     in
     let* () = Fs_util.atomic_write staged_path "half a body" in

     case "what a listing of the shard yields";
     let* listed = Local.list_prefix ~prefix:(chunk_prefix ^ shard) () in
     let listed =
       List.sort compare
         (List.map (fun (e : Backend.file_entry) -> e.Backend.key) listed)
     in
     show "listed" (List.map Filename.basename listed);
     check "the object is there" (List.mem chunk_key listed);
     check "the write in flight is not" (not (List.mem staged_key listed));
     check "and a user's own \".tmp\" still is" (List.mem user_key listed);
     step "on disk, though: %d file(s)"
       (List.length
          (keys_under (String.concat "/" [src_dir; chunk_prefix ^ shard])));
     check "the staged file was not deleted, only hidden"
       (Sys.file_exists staged_path);

     case "and a mirror asked to copy a store that lists one anyway";
     (* The source's listing hands out the staged key, so only the mirror's own
        guard stands between it and the copy. *)
     let* stale = Stale.list_prefix ~prefix:(chunk_prefix ^ shard) () in
     check "the source does offer it"
       (List.exists
          (fun (e : Backend.file_entry) -> e.Backend.key = staged_key)
          stale);
     let copied = ref [] in
     let* dests =
       M.resync ~source:"source"
         ~on_entry:(fun ~name:_ ~key ~size:_ ~outcome ->
           match outcome with
             | `Copied _ -> copied := key :: !copied
             | `Present -> ())
         ()
     in
     show "copied" (List.sort compare (List.map Filename.basename !copied));
     show "on the replica" (List.map mask (keys_under dst_dir));
     check "the object was copied" (List.mem chunk_key !copied);
     check "the write in flight was not" (not (List.mem staged_key !copied));
     check "so the replica holds nothing staged"
       (not
          (List.exists
             (fun k -> Fs_util.is_temp_name (Filename.basename k))
             (keys_under dst_dir)));
     check "and the accounts agree"
       ~why:(fun () ->
         String.concat ", "
           (List.map
              (fun d -> Printf.sprintf "%s: %d" d.Mirror.name d.Mirror.copied)
              dests))
       (List.for_all (fun d -> d.Mirror.copied = List.length !copied) dests);

     report ~expected:9 ();
     Scratch.cleanup root;
     Lwt.return_unit)
