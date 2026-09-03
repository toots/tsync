(* What a folder's children cost the walk that reads them.

   An emptied namespace lists as its own directory key, and a GET of one fails
   outright: the resync that counted that as a broken child never advanced its
   bookmark, so every later sync resynced the whole domain again. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "tree-children"

module Store =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Tree = Inode_tree_lwt.Make (C)

(* One key that will not read, so the batch fails whole and the walk has to
   decide what that costs its siblings. A wrapper rather than a chmod: the suite
   must behave the same as root. *)
let broken = ref (Stored_key.listed "")

module Flaky : Backend_lwt.Store = struct
  include Store

  let refuse key =
    Lwt.fail (Backend.Backend_error ("cannot read " ^ Stored_key.to_string key))

  let get ~key () = if key = !broken then refuse key else Store.get ~key ()

  let get_opt ~key () =
    if key = !broken then refuse key else Store.get_opt ~key ()

  let get_many = None
end

module Cf =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Flaky : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Tf = Inode_tree_lwt.Make (Cf)

(* Every listing costs a round trip's worth of waiting and is counted, so a
   walk shows how many it made and whether it made them in series. *)
let listings = ref 0
let listing_delay = 0.02

module Slow : Backend_lwt.Store = struct
  include Store

  let list_prefix ?max_keys ~prefix () =
    incr listings;
    let* () = Lwt_unix.sleep listing_delay in
    Store.list_prefix ?max_keys ~prefix ()
end

module Cs =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Slow : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Ts = Inode_tree_lwt.Make (Cs)
module Lk = Logical_key.Make (Cs)

let ns id = C.domain_prefix ^ id ^ "/"

let put id name body =
  Store.put
    ~key:(Stored_key.in_space ~prefix:(ns id) name)
    ~data:(Bigstring.of_string body) ()

let manifest_body name =
  Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

let is_file = function
  | { Inode_tree.body = Inode_tree.File _; _ } -> true
  | _ -> false

let is_dir = function
  | { Inode_tree.body = Inode_tree.Dir _; _ } -> true
  | _ -> false

let () =
  Lwt_main.run
    (case "an emptied namespace has no children";
     let emptied = Stored_key.new_id () in
     let* () = put emptied "gone" (manifest_body "gone.txt") in
     let* () =
       Store.delete ~key:(Stored_key.in_space ~prefix:(ns emptied) "gone") ()
     in
     let* listed = Store.list_prefix ~prefix:(ns emptied) () in
     (* The directory key is what the walk used to choke on, so a run where the
        store stopped listing one would prove nothing. *)
     check "the store still lists the namespace as a directory key"
       (List.exists
          (fun (e : Backend.file_entry) -> Stored_key.is_dir_key e.Backend.key)
          listed);
     let* children = Tree.children ~folder_id:emptied () in
     check "and it yields no children" (children = []);

     case "children are classified by their body";
     let mixed = Stored_key.new_id () in
     let* () = put mixed "a" (manifest_body "a.txt") in
     let* () =
       put mixed "b"
         (Folder.marker_to_string
            { Folder.name = "sub"; id = Stored_key.new_id () })
     in
     let* children = Tree.children ~folder_id:mixed () in
     check "one manifest" (List.length (List.filter is_file children) = 1);
     check "one marker" (List.length (List.filter is_dir children) = 1);

     case "an unusable body is reported, not raised";
     let junk = Stored_key.new_id () in
     let* () = put junk "a" (manifest_body "a.txt") in
     let* () = put junk "bad" "neither a marker nor a manifest" in
     let seen = ref [] in
     let* children =
       Tree.children
         ~on_unusable:(`Skip (fun bkey r -> seen := (bkey, r) :: !seen))
         ~folder_id:junk ()
     in
     check "the good child survives" (List.length children = 1);
     check "the bad one is reported once"
       (match !seen with
         | [(bkey, `Unclassifiable _)] ->
             bkey = Stored_key.in_space ~prefix:(ns junk) "bad"
         | _ -> false);

     (* [`Fail] is about a fetch that failed; a body that will not parse is a
        write in flight either way. *)
     let* children = Tree.children ~folder_id:junk () in
     check "and `Fail skips it just the same" (List.length children = 1);

     case "one object that will not read does not cost its siblings";
     let flaky = Stored_key.new_id () in
     let* () = put flaky "good" (manifest_body "good.txt") in
     let* () = put flaky "other" (manifest_body "other.txt") in
     let* () = put flaky "nope" (manifest_body "nope.txt") in
     broken := Stored_key.in_space ~prefix:(ns flaky) "nope";
     let seen = ref [] in
     let* children =
       Tf.children
         ~on_unusable:(`Skip (fun bkey r -> seen := (bkey, r) :: !seen))
         ~folder_id:flaky ()
     in
     check "the readable siblings still arrive" (List.length children = 2);
     check "and only the unreadable one is reported"
       (match !seen with
         | [(bkey, `Unreadable _)] -> bkey = !broken
         | _ -> false);
     (* A walk deciding what to delete must not take a failed read for an
        absent subtree. *)
     let* refused =
       Lwt.catch
         (fun () ->
           let+ _ = Tf.children ~folder_id:flaky () in
           false)
         (fun _ -> Lwt.return_true)
     in
     check "`Fail refuses the folder rather than shortening it" refused;
     broken := Stored_key.listed "";

     case "a walk fetches folders ahead of visiting them, in visit order";
     (* A root of eight folders holding seven each: 65 folders, 64 files. *)
     let top = Stored_key.new_id () in
     let mkdir parent name =
       let id = Stored_key.new_id () in
       let+ () =
         put parent name (Folder.marker_to_string { Folder.name; id })
       in
       id
     in
     let* () =
       Lwt_list.iter_s
         (fun i ->
           let* d = mkdir top (Printf.sprintf "d%d" i) in
           let* () = put d "f" (manifest_body "f.txt") in
           Lwt_list.iter_s
             (fun j ->
               let* e = mkdir d (Printf.sprintf "e%d" j) in
               put e "f" (manifest_body "f.txt"))
             (List.init 7 Fun.id))
         (List.init 8 Fun.id)
     in
     let walk ~width =
       let seen = ref [] in
       let slots = Io_lwt.Bounded.create ~max:width () in
       let+ () =
         Ts.fold_tree ~slots ~folder_id:top ~key:Lk.root
           (fun () key entry ->
             let opens =
               match entry.Inode_tree.body with
                 | Inode_tree.Dir m ->
                     Some
                       (Logical_key.path (Logical_key.dir_in key m.Folder.name))
                 | Inode_tree.File _ -> None
             in
             seen := (Logical_key.path key, opens) :: !seen;
             Lwt.return_unit)
           ()
       in
       List.rev !seen
     in
     listings := 0;
     let started = Unix.gettimeofday () in
     let* visits = walk ~width:8 in
     let elapsed = Unix.gettimeofday () -. started in
     let serial = 65. *. listing_delay in
     check "every folder is listed once" (!listings = 65);
     check "every entry is visited once" (List.length visits = 128);
     check "and the listings overlapped"
       (elapsed < serial /. 2.)
       ~why:(fun () ->
         Printf.sprintf "%.2fs for 65 listings of %.2fs" elapsed listing_delay);
     (* Depth-first: each visit is in the innermost folder still open, and a
        folder entry opens its folder for the visits that follow. *)
     let depth_first =
       let open_dirs = ref [""] in
       List.for_all
         (fun (dir, opens) ->
           let rec close = function
             | d :: rest when d <> dir -> close rest
             | stack -> stack
           in
           open_dirs := close !open_dirs;
           let ok = !open_dirs <> [] in
           Option.iter (fun d -> open_dirs := d :: !open_dirs) opens;
           ok)
         visits
     in
     check "in depth-first order" depth_first;
     let* single = walk ~width:1 in
     check "and the visit order does not depend on the width" (visits = single);
     Lwt.return_unit);
  report ~expected:15 ()
