(* A forked process draws ids of its own. The generator is seeded when the module
   loads, so a child that inherits the state replays its parent's sequence:
   the daemon's forked frontends named staged bodies and trash entries alike. *)

open Check

let draw_in_child () =
  let r, w = Unix.pipe () in
  match Unix.fork () with
    | 0 ->
        Unix.close r;
        let oc = Unix.out_channel_of_descr w in
        output_string oc (Id.short ());
        close_out oc;
        Unix._exit 0
    | pid ->
        Unix.close w;
        let ic = Unix.in_channel_of_descr r in
        let id = input_line ic in
        close_in ic;
        ignore (Unix.waitpid [] pid);
        id

let () =
  case "a forked child";
  (* In use before the fork, as it is in the daemon. *)
  ignore (Id.short ());
  let child = draw_in_child () in
  let parent = Id.short () in
  check "draws ids its parent does not"
    ~why:(fun () -> Printf.sprintf "both drew %s" child)
    (child <> parent);
  let sibling = draw_in_child () in
  check "and so does the next child" (sibling <> child && sibling <> parent);
  check "of the same shape"
    (List.for_all (fun id -> String.length id = 16) [child; parent; sibling]);
  report ~expected:3 ()
