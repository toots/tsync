(* What paces the poller, and what it hands the store to pace with.

   The loop used to sleep a constant, so nothing it did between ticks could be
   wrong about timing. It now waits on the store instead, which makes two things
   assertable that were not: that an idle client reads nothing at all, and that
   the token it offers is the entry key it last finished with rather than the
   one it merely saw. A pass that dies half way must keep offering the old one,
   or the wait it starts next is one the store answers by holding. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "cursor-watch"

(* The handshake is two mailboxes rather than a sleep: [watch] parks on [calls]
   until the test has read what it was handed, and on [gate] until the test lets
   it return, so every line below is ordered by the poller itself. *)
let calls : Backend.Watch_token.t option Lwt_mvar.t = Lwt_mvar.create_empty ()
let gate : unit Lwt_mvar.t = Lwt_mvar.create_empty ()
let cursor_reads = ref 0
let listings = ref 0
let listing_fails = ref false

exception Listing_failed

module Store : Backend_lwt.Store = struct
  let objects : (Stored_key.t, Bigstring.t) Hashtbl.t = Hashtbl.create 8

  let put ~key ~data () =
    Hashtbl.replace objects key data;
    Lwt.return_unit

  let get_opt ~key () =
    if Stored_key.to_string key = "tsync/testdom/cursor" then incr cursor_reads;
    Lwt.return (Hashtbl.find_opt objects key)

  let get_range ~key ~offset ~length () =
    Lwt.return
      (Option.map (Doubles.range_of ~offset ~length)
         (Hashtbl.find_opt objects key))

  let get ~key () =
    match Hashtbl.find_opt objects key with
      | Some d -> Lwt.return d
      | None ->
          Lwt.fail
            (Backend.Backend_error ("no such key: " ^ Stored_key.to_string key))

  let put_if_absent ~key ~data () =
    match Hashtbl.find_opt objects key with
      | Some held -> Lwt.return held
      | None ->
          let* () = put ~key ~data () in
          Lwt.return data

  let head_opt ~key () =
    Lwt.return
      (Option.map
         (fun d ->
           {
             Backend.key;
             size = Bigstring.length d;
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
    if String.starts_with ~prefix:"tsync/testdom/journal/" prefix then begin
      incr listings;
      if !listing_fails then raise Listing_failed
    end;
    Lwt.return
      (Hashtbl.fold
         (fun key d acc ->
           if Stored_key.is_in ~prefix key then
             {
               Backend.key;
               size = Bigstring.length d;
               last_modified = 0.;
               etag = None;
             }
             :: acc
           else acc)
         objects [])

  let watch ~key:_ ~last_seen () =
    let* () = Lwt_mvar.put calls last_seen in
    Lwt_mvar.take gate

  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let get_many = None
  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let local_path = None
end

module C =
  (val Fixture.conf ~domain:"testdom" ~store:(module Store) ~root ()
      : Conf_lwt.S)

module F = File_lwt.Make (C)
module Sp = Sync_lwt.Sync_poller.Make (C) (F)

let token_of s = Backend.Watch_token.of_body (Bigstring.of_string s)
let render = function None -> "none" | Some t -> Backend.Watch_token.to_wire t

(* Waits for the poller to reach its next wait, so what is read afterwards is
   the state a whole pass left behind. *)
let next_wait () = Lwt_mvar.take calls
let release () = Lwt_mvar.put gate ()

let set_cursor key =
  Store.put ~key:C.cursor_key ~data:(Bigstring.of_string key) ()

let () =
  Lwt_main.run
    (Sp.start ~on_changed:(fun _ -> ()) ();
     let reads = ref 0 and lists = ref 0 in
     (* Deltas, so no case inherits the previous one's totals. *)
     let since () =
       let r = !cursor_reads - !reads and l = !listings - !lists in
       reads := !cursor_reads;
       lists := !listings;
       (r, l)
     in

     case "an idle client reads nothing until the store says to";
     let* offered = next_wait () in
     check "the first wait is entered before any cursor read" (!cursor_reads = 0);
     check "and it offers nothing, never having read one"
       (render offered = "none");

     case "a wake on a moved cursor reads it and applies what it points past";
     let* () = set_cursor "0000000000100-peer" in
     let* () = release () in
     let* offered = next_wait () in
     let r, l = since () in
     step "cursor reads: %d, journal listings: %d" r l;
     check "the cursor was read once" (r = 1);
     check "and the journal listed once" (l = 1);
     check "the token now offered is what that pass finished with"
       (render offered = "0000000000100-peer");

     case "a wake on an unmoved cursor costs the read and nothing more";
     let* () = release () in
     let* offered = next_wait () in
     let r, l = since () in
     step "cursor reads: %d, journal listings: %d" r l;
     check "the cursor was read again" (r = 1);
     check "but the journal was not listed" (l = 0);
     check "and the token is unchanged" (render offered = "0000000000100-peer");

     case "a pass that dies keeps offering the token it last finished with";
     listing_fails := true;
     let* () = set_cursor "0000000000200-peer" in
     let* () = release () in
     let* offered = next_wait () in
     step "offered after the failed pass: %s" (render offered);
     check "the moved cursor is not offered"
       (render offered <> "0000000000200-peer");
     check "the token is the one from the last clean pass"
       (render offered = "0000000000100-peer");

     case "and it advances again once a pass completes";
     listing_fails := false;
     let* () = release () in
     let* offered = next_wait () in
     check "the token has caught up with the cursor"
       (render offered = "0000000000200-peer");
     check "a token off a body compares equal to one off the wire"
       (Backend.Watch_token.equal
          (token_of "0000000000200-peer")
          (Backend.Watch_token.of_wire " 0000000000200-peer\n"));
     Lwt.return_unit);
  Scratch.cleanup root
