(* What a partly filled file reports itself as.

   A body a read filled part of sits on disk under the name a whole one would,
   so anything asking "is this file here" by looking for that name answers yes
   over bytes that have never been fetched -- and `tsync ls' prints local for a
   file the network still owes. The record beside the body is what tells them
   apart, and this is the caller that has to consult it.

   The store is a real disk declaring itself slow, which is the only way to get
   a partly filled body on a machine whose backend is a disk: a fast store is
   asked for the whole body and there is nothing partial to report. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "partial-local"

module Disk =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

(* Everything a disk does, and none of its cheapness: reads take the range they
   were asked for, as they would over a link. *)
module Store : Backend_lwt.Store = struct
  include Disk

  let fast_read = false
end

module C =
  (val Fixture.conf ~domain:"testdom" ~chunk_size:8 ~cache_chunk_size:8
         ~store:(module Store : Backend_lwt.Store)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Lk = Logical_key.Make (C)
module R = Remote_lwt.Make (C)
module D = Data_lwt.Make (C) (R)
module Mf = Checkout_lwt.Make (C)

let body = "0123456789ABCDEFghijklmn"
let key = Lk.file "big.txt"
let local () = Checkout.is_local (Conf.locality (module C)) key

let read ~offset ~len =
  let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
  let+ (_ : int) = D.pread_key key buf ~offset:(Int64.of_int offset) in
  ()

let () =
  Lwt_main.run
    (let* () = Mf.ensure_root () in
     let src = Filename.concat root "src.txt" in
     let oc = open_out_bin src in
     output_string oc body;
     close_out oc;
     let* () = D.stage_whole key ~src_path:src in
     let* () = D.sync key () in
     let* () = D.forget_chunks key in

     case "a file whose chunks are all still remote";
     check "reads as cloud" (not (local ()));

     case "a file with a body for every chunk, one of them partly filled";
     (* Four bytes of the first chunk, then the whole of the other two, so every
        cache chunk of the file is a file on disk and only one of them has a
        hole in it. Anything reading presence alone answers local here. *)
     let* () = read ~offset:0 ~len:4 in
     let* () = read ~offset:8 ~len:16 in
     check "reads as cloud" (not (local ()));

     case "and once that hole is filled too";
     let* () = read ~offset:0 ~len:8 in
     check "reads as local" (local ());

     (* The whole point of keeping the bytes: what was read once is not fetched
        again, and the file stays local across a reopen. *)
     let* () = read ~offset:4 ~len:8 in
     check "and stays local" (local ());
     Lwt.return_unit);
  report ~expected:4 ()
