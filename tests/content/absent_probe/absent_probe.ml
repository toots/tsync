(* What a name that is not there costs.

   The mirror is the whole answer: the poller replays what peers published into
   it, so a name it does not carry is a name the domain does not have. A lookup
   that misses it must therefore stay off the network, and the reads are counted
   because the answer alone cannot say whether one was made.

   The last case is the window this buys: a key published straight to the store
   is not seen until the poller writes it, which is how the mount's own listing
   learns of it too. *)

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
  let list_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Lk = Logical_key.Make (C)
module R = Remote_lwt.Make (C)
module D = Data_lwt.Make (C) (R)
module Mf = Checkout_lwt.Make (C)
module Mirror = Manifests_lwt.Make (C)

let key name = Lk.file @@ name

let manifest name =
  Manifest.of_string
  @@ Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
       ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

(* Straight to the store, the way a peer publishes: nothing here writes the
   mirror, which is what the poller would do. *)
let publish_remotely name =
  Store.put
    ~key:
      (Stored_key.child_key ~prefix:C.domain_prefix
         ~folder_id:Stored_key.root_id name)
    ~data:(Manifest.body ~name (manifest name))
    ()

let found name =
  let+ m = D.published (key name) in
  Option.is_some m

let () =
  Lwt_main.run
    (let* () = Mf.ensure_root () in
     case "a name that is not there costs nothing";
     reads := 0;
     let* gone = found ".git" in
     check "the probe misses" (not gone);
     check "without reaching the backend" (!reads = 0);
     let* gone = found ".git" in
     check "and misses again" (not gone);
     check "still without reaching it" (!reads = 0);

     case "a name the mirror holds resolves";
     let* () = Mirror.write (key "here.txt") (manifest "here.txt") in
     reads := 0;
     let* there = found "here.txt" in
     check "it resolves" there;
     check "from the mirror alone" (!reads = 0);

     case "the mirror is the whole answer";
     let* () = publish_remotely "later.txt" in
     let* still = found "later.txt" in
     (* As stale as the mount's own listing, which learns the same way. *)
     check "a key only the store has is not seen" (not still);
     check "and is not asked after" (!reads = 0);
     let* () = Mirror.write (key "later.txt") (manifest "later.txt") in
     let* now = found "later.txt" in
     check "but is once the poller has written it" now;
     Lwt.return_unit);
  report ~expected:9 ()
