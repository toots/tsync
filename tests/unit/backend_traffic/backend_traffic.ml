(* What the transfer counters count.

   They are read by [tsync status] and by every job report, and the question
   they answer is "how much went over a link" — so a verb carrying no body must
   move them by nothing, a local store must move them by nothing, and a write
   reaching three stores must move them three times.

   The store here is in memory and registered under a type that is not "local",
   which is what puts it on the counted side of {!Backend.make}. *)

open Lwt.Syntax
open Check

let body n = Chunk.of_string (String.make n 'x')

module Memory () : Backend.S = struct
  let objects : (string, Chunk.t) Hashtbl.t = Hashtbl.create 8

  let put ~key ~data () =
    Hashtbl.replace objects key data;
    Lwt.return_unit

  (* The winner is handed back the very value it passed, which is what a real
     store does and what tells a win from a loss without comparing bodies. *)
  let put_if_absent ~key ~data () =
    match Hashtbl.find_opt objects key with
      | Some held -> Lwt.return held
      | None ->
          Hashtbl.replace objects key data;
          Lwt.return data

  let get_opt ~key () = Lwt.return (Hashtbl.find_opt objects key)

  let get ~key () =
    match Hashtbl.find_opt objects key with
      | Some d -> Lwt.return d
      | None -> Lwt.fail (Backend.Backend_error ("no such key: " ^ key))

  let head_opt ~key () =
    Lwt.return
      (Option.map
         (fun d ->
           {
             Backend.key;
             size = Chunk.length d;
             last_modified = 0.;
             etag = None;
           })
         (Hashtbl.find_opt objects key))

  let delete ~key () =
    Hashtbl.remove objects key;
    Lwt.return_unit

  let delete_multi keys =
    List.iter (Hashtbl.remove objects) keys;
    Lwt.return_unit

  let copy ~src_key ~dst_key () =
    (match Hashtbl.find_opt objects src_key with
      | Some d -> Hashtbl.replace objects dst_key d
      | None -> ());
    Lwt.return_unit

  let list_prefix ?max_keys:_ ~prefix () =
    Lwt.return
      (Hashtbl.fold
         (fun key d acc ->
           if String.starts_with ~prefix key then
             {
               Backend.key;
               size = Chunk.length d;
               last_modified = 0.;
               etag = None;
             }
             :: acc
           else acc)
         objects [])

  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let get_many = None

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

let () =
  Backend.register ~spec:[] "memory" (fun _ -> (module Memory () : Backend.S))

let remote () =
  Backend.make ~backend_type:"memory" ~get_field:(fun _ -> None) ()

(* A store holding its own counters, which is what a [member] carries so a
   report can name the link a transfer is on. *)
let remote_counted () =
  let traffic = Backend.new_traffic () in
  ( Backend.make ~traffic ~backend_type:"memory" ~get_field:(fun _ -> None) (),
    traffic )

(* What one store's own counters moved by, the same shape as [moved] so the two
   are read side by side. *)
let moved_on (t : Backend.traffic) f =
  let up = Metrics.total t.Backend.uploaded
  and down = Metrics.total t.Backend.downloaded in
  let+ () = f () in
  ( Metrics.total t.Backend.uploaded - up,
    Metrics.total t.Backend.downloaded - down )

(* Runs [f] and answers what it moved, so every assertion below is a number
   rather than the absence of one. *)
let moved f =
  let up = Metrics.uploaded () and down = Metrics.downloaded () in
  let+ () = f () in
  (Metrics.uploaded () - up, Metrics.downloaded () - down)

let expect name ~up ~down (u, d) =
  check name
    ~why:(fun () ->
      Printf.sprintf "up %d down %d, wanted up %d down %d" u d up down)
    (u = up && d = down)

let () =
  let scratch =
    Filename.concat (Filename.get_temp_dir_name ()) "tsync-traffic"
  in
  ignore
    (Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s" scratch scratch));
  Lwt_main.run
    (let (module R : Backend.S) = remote () in
     let (module L : Backend.S) =
       Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some scratch) ()
     in

     case "a body crossing a link is counted, once, for its own length";
     let* r = moved (fun () -> R.put ~key:"k" ~data:(body 100) ()) in
     expect "put counts its body up" ~up:100 ~down:0 r;
     let* r = moved (fun () -> Lwt.map ignore (R.get ~key:"k" ())) in
     expect "get counts its body down" ~up:0 ~down:100 r;
     let* r = moved (fun () -> Lwt.map ignore (R.get_opt ~key:"k" ())) in
     expect "get_opt counts a body it found" ~up:0 ~down:100 r;
     let* r = moved (fun () -> Lwt.map ignore (R.get_opt ~key:"absent" ())) in
     expect "get_opt counts nothing when there is nothing" ~up:0 ~down:0 r;

     case "a verb with no body moves nothing";
     let* r = moved (fun () -> Lwt.map ignore (R.head_opt ~key:"k" ())) in
     expect "head_opt" ~up:0 ~down:0 r;
     (* A listing carries every object's size, so summing it here would report
        the whole namespace as traffic on a call that fetched no bytes. *)
     let* r = moved (fun () -> Lwt.map ignore (R.list_prefix ~prefix:"" ())) in
     expect "list_prefix" ~up:0 ~down:0 r;
     let* r = moved (fun () -> R.delete ~key:"gone" ()) in
     expect "delete" ~up:0 ~down:0 r;
     let* r = moved (fun () -> R.delete_multi ["a"; "b"]) in
     expect "delete_multi" ~up:0 ~down:0 r;

     case "put_if_absent, whose loser is handed a body down the link";
     let* r =
       moved (fun () ->
           Lwt.map ignore (R.put_if_absent ~key:"race" ~data:(body 40) ()))
     in
     expect "winning sends and receives nothing back" ~up:40 ~down:0 r;
     let* r =
       moved (fun () ->
           Lwt.map ignore (R.put_if_absent ~key:"race" ~data:(body 40) ()))
     in
     expect "losing sends, and takes the winner's body" ~up:40 ~down:40 r;

     case "a local store is a filesystem, not a link";
     let* r = moved (fun () -> L.put ~key:"k" ~data:(body 100) ()) in
     expect "local put" ~up:0 ~down:0 r;
     let* r = moved (fun () -> Lwt.map ignore (L.get ~key:"k" ())) in
     expect "local get" ~up:0 ~down:0 r;

     case "a write reaching two stores is counted twice";
     let (module Composite : Backend.S) =
       Domain_store.make
         ~mains:
           [
             { Domain_store.name = "one"; backend = remote () };
             { Domain_store.name = "two"; backend = remote () };
           ]
         ~targets:[] ~archives:[]
     in
     let* r = moved (fun () -> Composite.put ~key:"fan" ~data:(body 70) ()) in
     expect "twice the bytes reach a link, so twice is the count" ~up:140
       ~down:0 r;
     (* A read stops at the first store that answers, so it is one body however
        many could have supplied it. *)
     let* r = moved (fun () -> Lwt.map ignore (Composite.get ~key:"fan" ())) in
     expect "a read is counted once" ~up:0 ~down:70 r;

     case "a store counts its own bytes as well as the process's";
     let (module One : Backend.S), t1 = remote_counted () in
     let (module Two : Backend.S), t2 = remote_counted () in
     let* r = moved_on t1 (fun () -> One.put ~key:"a" ~data:(body 25) ()) in
     expect "a put reaches the store's own counter" ~up:25 ~down:0 r;
     let* r = moved_on t1 (fun () -> Lwt.map ignore (One.get ~key:"a" ())) in
     expect "so does a get" ~up:0 ~down:25 r;
     (* The figure exists to say which link the bytes crossed, so a second store
        seeing the first's traffic would be the whole point missed. *)
     let* r = moved_on t2 (fun () -> One.put ~key:"b" ~data:(body 60) ()) in
     expect "one store's bytes are not another's" ~up:0 ~down:0 r;
     let* r = moved (fun () -> Two.put ~key:"b" ~data:(body 60) ()) in
     expect "and the process-wide count still takes every store's" ~up:60
       ~down:0 r;

     case "which stores have a link to count";
     check "a local store is a filesystem"
       (not (Backend.counts_traffic ~backend_type:"local"));
     check "a remote one is not" (Backend.counts_traffic ~backend_type:"memory");

     report ~expected:20 ();
     Lwt.return_unit)
