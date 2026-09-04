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
  let list_many = None
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
let listing_delay = ref 0.02

module Slow : Backend_lwt.Store = struct
  include Store

  let list_prefix ?max_keys ~prefix () =
    incr listings;
    let* () = Lwt_unix.sleep !listing_delay in
    Store.list_prefix ?max_keys ~prefix ()
end

module Cs =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Slow : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Ts = Inode_tree_lwt.Make (Cs)
module Lk = Logical_key.Make (Cs)

(* A store that answers many folders per request, as the proxy does, and can be
   made to answer fewer than it was asked for. Bodies come through [get_opt] so
   the walk's per-key reads are counted apart from the batch. *)
let batches = ref 0
let answer_at_most = ref max_int

module Many : Backend_lwt.Store = struct
  include Slow

  let list_many =
    Some
      (fun ~prefixes () ->
        incr batches;
        let asked = List.filteri (fun i _ -> i < !answer_at_most) prefixes in
        Lwt_list.map_s
          (fun prefix ->
            let* listed = Store.list_prefix ~prefix () in
            let+ bodies =
              Lwt_list.map_s
                (fun (e : Backend.file_entry) ->
                  let+ body = Store.get_opt ~key:e.Backend.key () in
                  (e.Backend.key, body))
                (List.filter
                   (fun (e : Backend.file_entry) ->
                     Stored_key.is_child_object e.Backend.key)
                   listed)
            in
            (prefix, { Backend.listed; bodies }))
          asked)
end

module Cm =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Many : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Tm = Inode_tree_lwt.Make (Cm)

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
     let timed ~width =
       let started = Unix.gettimeofday () in
       let+ visits = walk ~width in
       (visits, Unix.gettimeofday () -. started)
     in
     (* The same walk with no delay first, so the disk's share is measured on
        this machine at this moment rather than assumed: a slow one moves both
        figures, and only the waiting that did not overlap separates them. *)
     listing_delay := 0.;
     let* _, disk = timed ~width:8 in
     listing_delay := 0.02;
     listings := 0;
     let* visits, wide = timed ~width:8 in
     check "every folder is listed once" (!listings = 65);
     check "every entry is visited once" (List.length visits = 128);
     let serial = 65. *. !listing_delay in
     check "and the listings overlapped"
       (wide -. disk < serial /. 2.)
       ~why:(fun () ->
         Printf.sprintf
           "%.2fs with the delay, %.2fs without, 65 listings of %.2fs" wide disk
           !listing_delay);
     let* single, _ = timed ~width:1 in
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
     check "and the visit order does not depend on the width" (visits = single);

     case "a store that lists many folders at once is asked per batch";
     let walk_many ~width =
       let seen = ref [] in
       let slots = Io_lwt.Bounded.create ~max:width () in
       let+ () =
         Tm.fold_tree ~slots ~folder_id:top ~key:Lk.root
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
     batches := 0;
     let* batched = walk_many ~width:8 in
     check "the same tree comes back" (batched = visits);
     (* The root alone is fetched singly, nothing having listed it yet. *)
     check "the root is the only folder listed on its own" (!listings = 1);
     (* Its eight children in one request, and their fifty-six in another:
        each answer's subfolders are asked for together. *)
     check "and the rest come in two batches" (!batches = 2) ~why:(fun () ->
         Printf.sprintf "%d batches" !batches);

     case "a folder the store left out of its answer is asked for singly";
     listings := 0;
     batches := 0;
     answer_at_most := 1;
     let* partial = walk_many ~width:8 in
     check "the tree is still whole" (partial = visits);
     check "and the folders left out were listed on their own" (!listings > 1)
       ~why:(fun () -> Printf.sprintf "%d listings" !listings);
     answer_at_most := max_int;
     Lwt.return_unit);
  report ~expected:20 ()
