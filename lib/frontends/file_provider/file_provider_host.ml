open Tsync_core
open Tsync_owner

(* file-provider §13 changed_debounce. *)
let changed_debounce = 0.2

(* file-provider §8.1: the first change after a quiet period schedules one
   [changed] event [changed_debounce] later; changes meanwhile join it. *)
let debounced publish =
  let pending = Atomic.make false in
  fun () ->
    if Atomic.compare_and_set pending false true then
      Rt.spawn ~name:"changed" (fun () ->
          Rt.sleep changed_debounce;
          Atomic.set pending false;
          publish Protocol.Changed)

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
