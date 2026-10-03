(* A worker meeting an exception it did not expect while taking a record
   keeps running, and the record is retried (pitfall C-7.10). Its own process:
   the cases of dqueue_test leave fibers that delay a fresh queue's start. *)

open Tsync_core

let p fmt = Printf.printf fmt

(* A job is "<key>:<attempts>" on disk; its name decides how it fails. *)
let decode_fails = Atomic.make 0

let kind =
  {
    Dqueue.decode =
      (fun b ->
        if String.starts_with ~prefix:"boom" b && Atomic.get decode_fails > 0
        then (
          Atomic.decr decode_fails;
          failwith "decode raised");
        match String.split_on_char ':' b with
          | [k; n] -> Option.map (fun n -> (k, n)) (int_of_string_opt n)
          | _ -> None);
    encode = (fun (k, n) -> Printf.sprintf "%s:%d" k n);
    key = (fun (k, _) -> Some (List.hd (String.split_on_char '.' k)));
    note = (fun (k, n) _ -> (k, n + 1));
    accepts = (fun _ -> true);
  }

let log = ref []
let record s = log := s :: !log

let run _id (k, n) ~cancel =
  record (Printf.sprintf "%s#%d" k n);
  if String.starts_with ~prefix:"flaky" k && n < 2 then Fail.raise_ Link "flaky";
  if String.starts_with ~prefix:"refused" k then Fail.raise_ Refused "refused";
  (* Fails once, slowly and whatever its cancel, so a job posted for its key
     meanwhile is pending when it does. *)
  if String.starts_with ~prefix:"sf." k then (
    Rt.sleep 0.2;
    if n < 1 then Fail.raise_ Link "slow and flaky");
  if String.starts_with ~prefix:"slow" k then (
    Rt.sleep 0.2;
    if Atomic.get cancel then raise Rt.Cancelled)

let dir =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-dq-%d" (Unix.getpid ()))

let _settle q =
  Dqueue.settle ~timeout:5. q;
  Rt.sleep 0.05

let () =
  Fs.rm_rf dir;
  Rt.run_sync (fun () ->
      let rec wait q n =
        if n > 0 && not (Dqueue.idle q) then (
          Rt.sleep 0.1;
          wait q (n - 1))
      in
      let r = Dqueue.Records.open_ (Filename.concat dir "decode-raises") in
      let q =
        Dqueue.create ~workers:2 ~name:"decode-raises" ~ordered:false kind r
      in
      Dqueue.start q run;
      Atomic.set decode_fails 1;
      ignore (Dqueue.post q ("boom.1", 0));
      wait q 100;
      ignore (Dqueue.post q ("other.2", 0));
      wait q 100;
      p "ran: %s; idle: %b; records on disk: %d\n"
        (String.concat " " (List.rev !log))
        (Dqueue.idle q)
        (List.length (Dqueue.Records.list r)));
  Fs.rm_rf dir
