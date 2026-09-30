(* The process-wide stop of spec 01 §9. *)

exception Stopping

let () =
  Printexc.register_printer (function
    | Stopping -> Some "stopping: left for the next start"
    | _ -> None)

let m = Mutex.create ()
let requested_ = Atomic.make false
let hooks : (int * (unit -> unit)) list ref = ref []
let next_hook = ref 0
let signal = Rt.Promise.create ()
let requested () = Atomic.get requested_
let run_hook f = try f () with _ -> ()

let request () =
  if Atomic.compare_and_set requested_ false true then (
    let hs = Mutex.protect m (fun () -> List.rev !hooks) in
    List.iter (fun (_, f) -> run_hook f) hs;
    ignore (Rt.Promise.try_resolve signal ()))

(* A hook registered after the request runs at once. *)
let on_request f =
  let id =
    Mutex.protect m (fun () ->
        incr next_hook;
        hooks := (!next_hook, f) :: !hooks;
        !next_hook)
  in
  if requested () then run_hook f;
  fun () ->
    Mutex.protect m (fun () ->
        hooks := List.filter (fun (i, _) -> i <> id) !hooks)

let check () = if requested () then raise Stopping
let wait () = Rt.Promise.await signal

let sleep d =
  check ();
  Rt.first
    [
      (fun () -> Rt.sleep d);
      (fun () ->
        wait ();
        raise Stopping);
    ]

let grace = 10.
