(* How many times a burst of cursor bumps reaches the store.

   The cursor is one object name, and a store caps writes to a single name at
   about one a second: [rm -rf] of a few hundred files bumped it once per file
   and spent most of its time being told 429. So the assertions here are counts
   of writes, not of calls — a debouncer that publishes everything it is handed
   passes every other kind of check.

   The last case is the one that decides where the state lives: {!File_store} is
   applied once per module that touches the journal, so a per-application
   debouncer would give each of them its own and a flush would reach none of the
   others. *)

open Lwt.Syntax

let interval = 0.5
let root = Scratch.dir "cursor-debounce"

(* Counts what reaches the store, which is the figure the rate limit is on. *)
let puts = ref 0

module Counting : Backend.S = struct
  let objects : (string, Chunk.t) Hashtbl.t = Hashtbl.create 8

  let put ~key ~data () =
    incr puts;
    Hashtbl.replace objects key data;
    Lwt.return_unit

  let put_if_absent ~key ~data () =
    match Hashtbl.find_opt objects key with
      | Some held -> Lwt.return held
      | None ->
          let* () = put ~key ~data () in
          Lwt.return data

  let get_opt ~key () = Lwt.return (Hashtbl.find_opt objects key)

  let get ~key () =
    match Hashtbl.find_opt objects key with
      | Some d -> Lwt.return d
      | None -> Lwt.fail (Backend.Backend_error ("no such key: " ^ key))

  let head_opt ~key () =
    Lwt.return
      (Option.map
         (fun d -> { Backend.key; size = Chunk.length d; last_modified = 0. })
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
             { Backend.key; size = Chunk.length d; last_modified = 0. } :: acc
           else acc)
         objects [])

  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let get_many = None

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

module C =
  (val Fixture.conf ~domain:"testdom" ~store:(module Counting) ~root ()
      : Conf.S)

module Fs = File_store.Make (C)

(* A key by its timestamp, rather than from the generator: the forward-only case
   needs one that is older than a key already handed over. *)
let ek ms =
  match Journal.Entry_key.of_string (Printf.sprintf "%013d-uuid" ms) with
    | Some k -> k
    | None -> failwith "bad entry key"

let published () =
  let+ cursor = Fs.fetch_cursor () in
  Option.value ~default:"none" (Option.map Journal.Entry_key.to_string cursor)

let say fmt = Printf.printf fmt

(* Writes are counted rather than timed: what the rate limit is on is how many
   reached the store, and every figure printed below is a delta so a case cannot
   inherit the previous one's total. *)
let counted () = !puts

let () =
  File_store.set_cursor_flush_interval interval;
  Lwt_main.run
    (say "a bump on a quiet cursor publishes before it returns\n";
     let before = counted () in
     let* () = Fs.bump_cursor (ek 100) in
     say "  writes: %d\n" (counted () - before);
     let* p = published () in
     say "  cursor: %s\n\n" p;

     say "a burst behind it collapses to one\n";
     let burst = List.init 60 (fun i -> ek (200 + i)) in
     let before = counted () in
     let* () = Lwt_list.iter_s Fs.bump_cursor burst in
     say "  writes for %d bumps inside the interval: %d\n" (List.length burst)
       (counted () - before);
     let* () = Lwt_unix.sleep (interval *. 2.) in
     say "  writes once the timer has run: %d\n" (counted () - before);
     let* p = published () in
     say "  cursor: %s\n\n" p;

     say "an older key behind a newer one is already covered\n";
     let before = counted () in
     Fs.note_cursor (ek 500);
     Fs.note_cursor (ek 400);
     let* () = Fs.flush_cursor () in
     say "  writes: %d\n" (counted () - before);
     let* p = published () in
     say "  cursor: %s\n\n" p;

     say "a flush does not wait the interval out\n";
     let before = counted () in
     Fs.note_cursor (ek 600);
     let started = Unix.gettimeofday () in
     let* () = Fs.flush_cursor () in
     let elapsed = Unix.gettimeofday () -. started in
     say "  writes: %d\n" (counted () - before);
     say "  returned inside the interval: %b\n" (elapsed < interval);
     let before = counted () in
     let* () = Fs.flush_cursor () in
     say "  writes with nothing pending: %d\n\n" (counted () - before);

     say "every application of the functor shares one debouncer\n";
     (* The regression guard for module-level state: bumped through one
        instantiation and flushed through another, as the daemon does — the
        queue notes through {!Sync_queue}'s and drain flushes through the
        engine's. A per-application debouncer fails only here. *)
     let module Other = File_store.Make (C) in
     let before = counted () in
     Fs.note_cursor (ek 700);
     let* () = Other.flush_cursor () in
     say "  writes seen by a flush elsewhere: %d\n" (counted () - before);
     let+ p = published () in
     say "  cursor: %s\n" p)
