(* Telling the sync layer a record is owed.

   The signal arrives from a file operation and is taken up by a worker loop,
   and the two are not in step: a close happens whenever a handle closes, and
   the loop is waiting only between jobs. So what is pinned here is that a
   signal sent while nobody waits is still delivered -- the case a bare
   condition variable loses, and losing one means an upload that waits for the
   next start. *)

open Lwt.Syntax
open Check
module O = Owed.Make (Io_lwt.Lock)

(* What Wal hands over: the record, under the key it was written with. *)

let key n =
  match Journal.Entry_key.of_string n with
    | Some k -> k
    | None -> failwith ("not an entry key: " ^ n)

let record rel =
  {
    Wal.ops = [`Put (rel, 1L)];
    state = Wal.Prepared;
    attempts = 0;
    last_error = None;
  }

let rel_of (r : Wal.record) =
  match r.Wal.ops with `Put (rel, _) :: _ -> rel | _ -> "?"

let () =
  Lwt_main.run
    (let t = O.create () in

     case "signalled before anyone waits";
     O.signal t (key "0000000000001-aaaa", record "a.txt");
     check "is held" (O.pending t = 1);
     let* _, r = O.next t in
     check "and delivered to whoever waits next" (rel_of r = "a.txt");
     check "and taken off" (O.pending t = 0);

     case "two signalled before either is taken";
     O.signal t (key "0000000000002-aaaa", record "b.txt");
     O.signal t (key "0000000000003-aaaa", record "c.txt");
     check "both are held" (O.pending t = 2);
     let* _, first = O.next t in
     let* _, second = O.next t in
     check "in the order they were signalled"
       (rel_of first = "b.txt" && rel_of second = "c.txt");

     case "waiting first";
     let waited = O.next t in
     check "does not finish while nothing is owed" (Lwt.state waited = Lwt.Sleep);
     O.signal t (key "0000000000004-aaaa", record "d.txt");
     let+ _, r = waited in
     check "and finishes when one arrives" (rel_of r = "d.txt");
     report ~expected:7 ())
