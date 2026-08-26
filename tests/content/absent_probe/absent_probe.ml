(* What a name that is not there costs.

   A lookup that misses the mirror falls through to the backend, and a miss
   leaves nothing behind to find: a shell probing for [.git] in every parent
   directory, once per prompt, paid a round trip each time. The reads are
   counted, since the answers are the same either way and only the cost differs.

   The last two cases are the guard on the other side: the fallback exists for a
   file this client has not learned about yet, so an absence must stop being
   believed once the journal moves. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "absent-probe"
let reads = ref 0

module Disk =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module Store : Backend_lwt.Store = struct
  include Disk

  let get_opt ~key () =
    incr reads;
    Disk.get_opt ~key ()

  let get_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Lk = Logical_key.Make (C)
module R = Remote.Make (C)
module D = Data_lwt.Make (C) (R)
module Mf = Checkout_lwt.Make (C)
module Mfs = Staged_lwt.Manifest.Make (C)
module Fs = File_store.Make (C)
module J = Journal.Make (C)

let key name = Lk.file @@ name

let publish name =
  let body =
    Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
      ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]
  in
  Store.put
    ~key:
      (Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id name)
    ~data:(Bigstring.of_string body) ()

let found name =
  let+ m = D.published (key name) in
  Option.is_some m

let () =
  Lwt_main.run
    (let* () = Mf.ensure_root () in
     case "a name that is not there is asked about once";
     reads := 0;
     let* gone = found ".git" in
     check "the first probe misses" (not gone);
     let asked = !reads in
     check "and it reached the backend" (asked > 0);
     let* gone = found ".git" in
     check "the second probe still misses" (not gone);
     check "without asking again" (!reads = asked);

     case "a name that is there is unaffected";
     let* () = publish "here.txt" in
     let* there = found "here.txt" in
     check "it resolves" there;

     case "an absence is dropped once the journal moves";
     let* gone = found "later.txt" in
     check "not there yet" (not gone);
     let* () = publish "later.txt" in
     let* still = found "later.txt" in
     (* The window this trades for the round trips: as stale as the mount's own
        listing, which learns the same way. *)
     check "and is not seen while the mark stands" (not still);
     Fs.write_last_sync_key (J.entry_key ());
     let* now = found "later.txt" in
     check "but is once the mark has moved" now;

     (* Only the store's own answer is worth remembering. Not knowing a key's
        folder yet is a fact about this client, and nothing that fixes it moves
        the mark, so remembering it was an ENOENT that never lifted. *)
     case "a folder this client has not learned is not an absence";
     let deep = "unknown-folder/inside.txt" in
     let* gone = found deep in
     check "a key under an unknown folder finds nothing" (not gone);
     let* () =
       (* What the folder's own marker being learned looks like, which is a
          local write and moves no mark. *)
       Folder_ids_lwt.write ~cache_root:C.cache_root ~domain_name:C.domain_name
         (Lk.dir "unknown-folder")
         { Folder.name = "unknown-folder"; id = Stored_key.root_id }
     in
     let* () = publish "inside.txt" in
     let* now = found deep in
     check "and is asked again once the folder is known" now;
     Lwt.return_unit);
  report ~expected:10 ()
