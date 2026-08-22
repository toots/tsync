(* What a folder costs to read a second time.

   A store with no multi-object read answers a folder in a round trip per child.
   The index holds those bodies together so the listing is followed by one read,
   and the counts below are the whole point: the bodies come back the same
   either way and only the cost differs.

   The versions are the test's own, as an object store's are: an entry is used
   only while the listing still reports the one it was recorded under, so the
   last case is the one that says the cache cannot go stale. *)

open Lwt.Syntax

let root = Scratch.dir "folder-index"
let versions : (string, string) Hashtbl.t = Hashtbl.create 16
let index_reads = ref 0
let child_reads = ref 0
let index_writes = ref 0

module Disk =
  (val Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

(* A version per key, bumped on every write, which is what S3 and GCS report and
   a filesystem does not. *)
module Store : Backend.S = struct
  include Disk

  let bump key =
    let n =
      match Hashtbl.find_opt versions key with
        | Some v -> 1 + int_of_string v
        | None -> 1
    in
    Hashtbl.replace versions key (string_of_int n)

  let put ~key ~data () =
    if Folder.is_index_key key then incr index_writes;
    bump key;
    Disk.put ~key ~data ()

  let get_opt ~key () =
    if Folder.is_index_key key then incr index_reads else incr child_reads;
    Disk.get_opt ~key ()

  let list_prefix ?max_keys ~prefix () =
    let+ entries = Disk.list_prefix ?max_keys ~prefix () in
    List.map
      (fun (e : Backend.file_entry) ->
        { e with Backend.etag = Hashtbl.find_opt versions e.Backend.key })
      entries

  let get_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend.S)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Tree = Inode_tree.Make (C)

(* The same store, described as two a read could land on. A body answered by
   the second would carry the first's version into the index, so a domain like
   this holds none. *)
module Two =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend.S)
         ~members:
           [
             Backend.member ~name:"one" (module Store : Backend.S);
             Backend.member ~name:"two" ~role:"replica"
               (module Store : Backend.S);
           ]
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Tree_two = Inode_tree.Make (Two)

let folder = Folder.new_id ()

let manifest name =
  Chunk_table.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

let other = Folder.new_id ()

let write_in folder_id name body =
  Store.put
    ~key:(C.domain_prefix ^ folder_id ^ "/" ^ name)
    ~data:(Bigstring.of_string body) ()

let write name body = write_in folder name body

let reset () =
  index_reads := 0;
  child_reads := 0;
  index_writes := 0

let report label children =
  Printf.printf "%s\n" label;
  Printf.printf "  children read back: %d\n" (List.length children);
  Printf.printf "  index reads:        %d\n" !index_reads;
  Printf.printf "  child reads:        %d\n" !child_reads;
  Printf.printf "  index writes:       %d\n\n" !index_writes

let () =
  Lwt_main.run
    (let* () = write "a" (manifest "a.txt") in
     let* () = write "b" (manifest "b.txt") in
     let* () = write "c" (manifest "c.txt") in

     reset ();
     let* children = Tree.children ~refresh_index:true ~folder_id:folder () in
     report "a folder with no index yet" children;

     reset ();
     let* children = Tree.children ~refresh_index:true ~folder_id:folder () in
     report "the same folder, now indexed" children;

     let* () = write "b" (manifest "b.txt") in
     reset ();
     let* children = Tree.children ~refresh_index:true ~folder_id:folder () in
     report "after one child is rewritten" children;

     (* A caller that may not write — a share being served, a read-only domain
        — leaves the folder as it found it, however much it would have gained. *)
     let* () = write_in other "a" (manifest "a.txt") in
     let* () = write_in other "b" (manifest "b.txt") in
     reset ();
     let* children = Tree.children ~folder_id:other () in
     report "a folder read by someone who may not write" children;
     reset ();
     let* children = Tree.children ~folder_id:other () in
     report "and so still has no index the next time" children;

     (* [folder] has an index by now, and this domain must not touch it. *)
     reset ();
     let* children =
       Tree_two.children ~refresh_index:true ~folder_id:folder ()
     in
     report "a domain with two stores a read could land on" children;
     Lwt.return_unit)
