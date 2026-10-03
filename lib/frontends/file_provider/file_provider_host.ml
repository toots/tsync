open Tsync_core
open Tsync_owner

(* file-provider §13 changed_debounce. *)
let changed_debounce = 0.2

(* file-provider §8.1: the first change after a quiet period schedules one
   [changed] event [changed_debounce] later; changes meanwhile join it. *)
let debounced publish =
  let pending = Atomic.make false in
  fun () ->
    if Atomic.compare_and_set pending false true then (
      (* Pitfall C-7.10: a raising sleep or spawn must not leave every later
         change waiting on an event nobody will send. *)
      try
        Rt.spawn ~name:"changed" (fun () ->
            Fun.protect
              ~finally:(fun () -> Atomic.set pending false)
              (fun () -> Rt.sleep changed_debounce);
            publish Protocol.Changed)
      with e ->
        Atomic.set pending false;
        raise e)

let present _domain _engine ~publish =
  let changed = debounced publish in
  ( {
      Handler.no_hooks with
      changed = (fun _ -> changed ());
      reannounce = changed;
    },
    ignore )

let host ~mount:_ _domains ~run = run present
let () = Owner.register_host "file_provider" host
