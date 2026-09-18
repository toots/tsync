(* A read that answers for its bytes. The store mangles a set number of reads at
   the right length, which is the damage nothing short of hashing can see. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "verified-fetch"
let mangle_next = ref 0
let reads = ref 0

module Real = (val Fixture.local_store (Filename.concat root "store"))

module Mangling : Backend_lwt.Store = struct
  include Real

  let mangled body =
    incr reads;
    if !mangle_next = 0 then body
    else begin
      decr mangle_next;
      Bigstring.of_string
        (String.map
           (fun c -> Char.chr (Char.code c lxor 0xff))
           (Bigstring.to_string body))
    end

  let get ~key () = Lwt.map mangled (Real.get ~key ())
  let get_opt ~key () = Lwt.map (Option.map mangled) (Real.get_opt ~key ())
  let get_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom" ~chunk_size:8
         ~store:(module Mangling : Backend_lwt.Store)
         ~members:
           [Backend.member ~name:"local" (module Mangling : Backend_lwt.Store)]
         ~root ())

module Lk = Logical_key.Make (C)
module R = Remote_lwt.Make (C)

let body = "eight by"

let upload () =
  let src = Filename.concat root "src" in
  let oc = open_out_bin src in
  output_string oc body;
  close_out oc;
  R.upload ~key:(Lk.file "a.bin") ~src_path:src ~mtime:0. ~chunk_size:8 ()

let outcome chunk_key =
  reads := 0;
  Lwt.catch
    (fun () ->
      let+ got = R.get_verified_chunk ~chunk_key in
      `Body (Bigstring.to_string got))
    (fun exn -> Lwt.return (`Failed (Printexc.to_string exn)))

let () =
  Lwt_main.run
    (let* manifest = upload () in
     let chunk_key = Manifest.key manifest 0 in

     let* got = outcome chunk_key in
     check "a good body is handed over" (got = `Body body);
     check "at the cost of one read" (!reads = 1);

     mangle_next := 1;
     let* plain = R.get_chunk ~chunk_key in
     check "an unverified read takes a mangled body at its word"
       (Bigstring.to_string plain <> body);

     mangle_next := 1;
     let* got = outcome chunk_key in
     check "a body mangled once is read again" (got = `Body body);
     check "which is the second read" (!reads = 2);

     mangle_next := 2;
     let* got = outcome chunk_key in
     check "a body wrong twice is refused, by the key it was asked for"
       ~why:(fun () -> match got with `Failed m -> m | `Body b -> b)
       (match got with
         | `Failed message ->
             let contains ~sub s =
               let n = String.length sub in
               let rec at i =
                 i + n <= String.length s
                 && (String.sub s i n = sub || at (i + 1))
               in
               at 0
             in
             contains ~sub:chunk_key message
         | `Body _ -> false);
     check "after two reads and no third" (!reads = 2);

     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:7 ()
