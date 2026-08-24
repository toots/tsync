(* What a batched read costs, and that declaring one changes nothing but the
   cost.

   Bodies alone would come back right whether or not anything was batched, so
   the requests are counted: a store with a native batch must answer a folder in
   one, and one without must answer it key by key. *)

open Lwt.Syntax
open Check

let objects : (Stored_key.t, string) Hashtbl.t = Hashtbl.create 16
let reads = ref 0
let batches = ref 0
let body key = Option.map Bigstring.of_string (Hashtbl.find_opt objects key)

module Base = struct
  let unsupported () = Lwt.fail (Backend.Backend_error "not part of this test")
  let put ~key:_ ~data:_ () = unsupported ()
  let put_if_absent ~key:_ ~data:_ () = unsupported ()
  let get ~key:_ () = unsupported ()

  let get_opt ~key () =
    incr reads;
    Lwt.return (body key)

  let head_opt ~key:_ () = unsupported ()
  let delete ~key:_ () = unsupported ()
  let delete_multi _ = unsupported ()
  let copy ~src_key:_ ~dst_key:_ () = unsupported ()
  let list_prefix ?max_keys:_ ~prefix:_ () = unsupported ()
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

module Plain : Backend.S = struct
  include Base

  let get_many = None
end

module Native : Backend.S = struct
  include Base

  let get_many =
    Some
      (fun ~entries () ->
        incr batches;
        Lwt.return
          (List.map
             (fun (e : Backend.file_entry) ->
               (e.Backend.key, body e.Backend.key))
             entries))
end

module Bp = Backend.Batched (Plain)
module Bn = Backend.Batched (Native)

let entry ?(size = 1) key =
  Backend.{ key; size; last_modified = 0.; etag = None }

let rendered =
  List.map (fun (k, b) ->
      (Stored_key.to_string k, Option.map Bigstring.to_string b))

let () =
  Hashtbl.replace objects (Stored_key.listed "a") "alpha";
  Hashtbl.replace objects (Stored_key.listed "c") "gamma";
  let mixed =
    [
      entry (Stored_key.listed "a");
      entry (Stored_key.listed "b");
      entry (Stored_key.listed "c");
    ]
  in
  Lwt_main.run
    (case "a declared batch changes the cost, not the answer";
     reads := 0;
     batches := 0;
     let* without = Bp.get_many ~entries:mixed () in
     let cost_without = !reads in
     reads := 0;
     let* with_ = Bn.get_many ~entries:mixed () in
     check "the two paths agree" (rendered without = rendered with_);
     check "an absent key answers None"
       (rendered with_ = [("a", Some "alpha"); ("b", None); ("c", Some "gamma")]);
     check "with no native batch, a key is a read" (cost_without = 3);
     check "with one, the whole run is a request" (!batches = 1 && !reads = 0);

     case "a run is bounded by count and by bytes";
     batches := 0;
     let many =
       List.init 300 (fun i -> entry (Stored_key.listed (string_of_int i)))
     in
     let* _ = Bn.get_many ~entries:many () in
     check "300 keys is two requests, not one" (!batches = 2);
     batches := 0;
     let big =
       List.init 3 (fun i ->
           entry
             ~size:(4 * 1024 * 1024)
             (Stored_key.listed ("b" ^ string_of_int i)))
     in
     let* _ = Bn.get_many ~entries:big () in
     check "and so is 12 MB of bodies" (!batches = 2);
     Lwt.return_unit);
  report ~expected:6 ()
