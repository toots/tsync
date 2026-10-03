(* Spec 01 §6.5, measured from outside the runtime: a plain system thread
   plays a client of an IPC server while may-block work holds the runtime's
   slots. Linux only for the context-switch counts. *)

open Tsync_core
module Ipc = Tsync_ipc.Ipc

let line fd request =
  let request = request ^ "\n" in
  ignore (Unix.write_substring fd request 0 (String.length request));
  let byte = Bytes.create 1 in
  let rec skip () =
    match Unix.read fd byte 0 1 with
      | 0 -> failwith "closed"
      | _ -> if Bytes.get byte 0 <> '\n' then skip ()
  in
  skip ()

let connect path =
  let fd = Unix.socket PF_UNIX SOCK_STREAM 0 in
  Unix.connect fd (ADDR_UNIX path);
  fd

(* Latencies in milliseconds of [count] requests, [gap] seconds apart; a
   request unanswered after [limit] seconds ends the series. *)
let series ?(gap = 0.) ?(limit = 5.) path request count =
  let fd = connect path in
  Unix.setsockopt_float fd SO_RCVTIMEO limit;
  let rec go n acc =
    if n = 0 then acc
    else (
      let t0 = Unix.gettimeofday () in
      match line fd request with
        | () ->
            let d = (Unix.gettimeofday () -. t0) *. 1000. in
            if gap > 0. then Unix.sleepf gap;
            go (n - 1) (d :: acc)
        | exception _ -> acc)
  in
  let l = go count [] in
  Unix.close fd;
  List.sort Float.compare l

let quantile l q =
  match l with
    | [] -> nan
    | _ ->
        List.nth l
          (min (List.length l - 1) (int_of_float (q *. float (List.length l))))

let switches () =
  match Sys.readdir "/proc/self/task" with
    | exception Sys_error _ -> None
    | tasks ->
        Some
          (Array.fold_left
             (fun total task ->
               match
                 In_channel.with_open_text
                   ("/proc/self/task/" ^ task ^ "/status")
                   In_channel.input_all
               with
                 | exception Sys_error _ -> total
                 | status ->
                     List.fold_left
                       (fun total l ->
                         match String.split_on_char ':' l with
                           | [k; v]
                             when k = "voluntary_ctxt_switches"
                                  || k = "nonvoluntary_ctxt_switches" ->
                               total + int_of_string (String.trim v)
                           | _ -> total)
                       total
                       (String.split_on_char '\n' status))
             0 tasks)

let cpu () =
  let t = Unix.times () in
  t.tms_utime +. t.tms_stime

let report name ~asked l ~wall ~cpu:c ~switched =
  Printf.printf
    "%-34s answered %5d/%-5d  p50 %8.3f ms  p99 %8.3f ms  max %8.3f ms" name
    (List.length l) asked (quantile l 0.5) (quantile l 0.99) (quantile l 1.);
  Printf.printf "  wall %6.2f s  cpu %5.2f s" wall c;
  (match switched with
    | Some s when l <> [] ->
        Printf.printf "  %5.1f switches/request"
          (float s /. float (List.length l))
    | _ -> ());
  Printf.printf "\n%!"

let measure name ?gap ?limit path request count =
  let s0 = switches () and c0 = cpu () and t0 = Unix.gettimeofday () in
  let l = series ?gap ?limit path request count in
  let switched =
    match (s0, switches ()) with Some a, Some b -> Some (b - a) | _ -> None
  in
  report name ~asked:count l
    ~wall:(Unix.gettimeofday () -. t0)
    ~cpu:(cpu () -. c0)
    ~switched

let ping = {|{"action":"ping"}|}
let other = {|{"action":"other"}|}

let () =
  let dir = Filename.temp_dir "tsync-bench" "" in
  Unix.chmod dir 0o700;
  let path = Filename.concat dir "s" in
  ignore
    (Rt.run_sync (fun () -> Ipc.serve ~path (fun _ -> Ipc.Reply (Ipc.ok []))));
  measure "idle, ping" path ping 20000;
  measure "idle, handled request" path other 20000;
  (* A slow disk: every slot is in a 0.5 s blocking call, with more waiting. *)
  let slow = Atomic.make true in
  for _ = 1 to 1000 do
    Rt.spawn (fun () ->
        while Atomic.get slow do
          Unix.sleepf 0.5;
          Rt.yield ()
        done)
  done;
  Unix.sleepf 1.;
  measure "slow disk, ping" ~gap:0.01 path ping 300;
  measure "slow disk, handled request" ~gap:0.01 path other 300;
  Atomic.set slow false;
  Unix.sleepf 2.;
  (* A dead disk: every slot is in a call that does not return. *)
  let hold, release = Unix.pipe () in
  for _ = 1 to 300 do
    Rt.spawn (fun () -> ignore (Unix.read hold (Bytes.create 1) 0 1))
  done;
  Unix.sleepf 1.;
  measure "dead disk, ping" ~gap:0.01 ~limit:3. path ping 100;
  measure "dead disk, handled request" ~limit:3. path other 1;
  ignore (Unix.write release (Bytes.make 300 'x') 0 300);
  exit 0
