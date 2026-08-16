(* A queue that has stopped working says so.

   Every way one has gone quiet in practice looks identical from outside: a
   worker stuck inside [run] waiting on a reply that never comes, one parked
   while work waits, one whose promise is gone. None of them raise, none return,
   none log, and [stats] keeps reporting the jobs as merely queued. What can be
   observed is the absence — work owed and nothing finishing it — so that is
   what is asserted here, in both directions: a queue that is working must stay
   quiet, or the warning would mean nothing. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "queue-stall"

module Q = Durable_queue.Make (struct
  type t = string

  let to_string s = s
  let of_string s = Some s
end)

let stalls () =
  List.filter
    (fun (_, _, msg) ->
      String.length msg > 0
      &&
      let needle = "none finished in" in
      let n = String.length msg and m = String.length needle in
      let rec go i =
        i + m <= n && (String.sub msg i m = needle || go (i + 1))
      in
      go 0)
    (Log.recent ())

let queue ~name ~dir ~run =
  Q.ordered ~name
    ~log:(Q.Records.create ~dir:(Filename.concat root dir))
    ~poison:Durable_queue.Drop ~run ()

let () =
  Durable_queue.set_stall_warning_interval 0.2;
  Lwt_main.run
    (let before = List.length (stalls ()) in

     let done_q =
       queue ~name:"working" ~dir:"working" ~run:(fun _ -> Lwt.return_unit)
     in
     Q.start done_q;
     let* () = Q.post done_q "a" in
     let* () = Q.post done_q "b" in
     let* () = Lwt_unix.sleep 0.7 in
     check "a queue that drains says nothing" (List.length (stalls ()) = before);
     check "and it really did drain" ((Q.stats done_q).Durable_queue.queued = 0);

     (* A job that never finishes, which is what a request with no reply and no
        timeout looks like from here. *)
     let forever, _ = Lwt.wait () in
     let stuck_q = queue ~name:"stuck" ~dir:"stuck" ~run:(fun _ -> forever) in
     Q.start stuck_q;
     let* () = Q.post stuck_q "one" in
     let* () = Q.post stuck_q "two" in
     let* () = Q.post stuck_q "three" in
     let* () = Lwt_unix.sleep 0.7 in
     check "a queue holding jobs with nothing finishing warns"
       (List.length (stalls ()) > before);
     check "and still reports them as merely queued"
       ((Q.stats stuck_q).Durable_queue.queued > 0);

     report ();
     Lwt.return_unit)
