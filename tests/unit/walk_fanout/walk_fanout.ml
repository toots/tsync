(* What listing a store's tree costs while it is being listed.

   The walk is bounded where it takes its slots, which covers the stat calls and
   says nothing about the tasks waiting to make one. A task per entry is the
   tree's size in promises, and because every level awaits the one below, the
   whole tree's worth is alive at once: half a million manifests came to a
   hundred megabytes of pending promises, closures and queue cells before the
   first key was returned.

   So what is measured is the peak heap the call reaches, per entry it returns.
   [top_heap_words] is the high-water mark rather than what survives, which is
   the only figure that sees a cost paid entirely inside one call. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "walk-fanout"
let store = Filename.concat root "store"
let dirs = 16
let per_dir = 500
let entries = dirs * per_dir

module B =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some store)
         ()
      : Backend_lwt.Store)

let plant () =
  for d = 0 to dirs - 1 do
    let p = Filename.concat store (Printf.sprintf "objs/%04x" d) in
    ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote p)));
    for k = 0 to per_dir - 1 do
      let oc = open_out (Filename.concat p (Printf.sprintf "%08x" k)) in
      output_string oc "x";
      close_out oc
    done
  done

let peak () = (Stdlib.Gc.stat ()).Stdlib.Gc.top_heap_words

let () =
  plant ();
  Lwt_main.run
    (case "listing a tree does not cost a task per entry";
     (* The first call, and the only one: [top_heap_words] is a high-water mark
        that never comes back down, so a warm-up would already have set it. *)
     let before = peak () in
     let* listed = B.list_prefix ~prefix:"objs/" () in
     let grew = peak () - before in
     check "every planted object came back"
       ~why:(fun () ->
         Printf.sprintf "%d listed, %d planted" (List.length listed) entries)
       (List.length listed = entries);
     let per_entry = grew / entries in
     check "the peak the walk reaches does not scale with the tree"
       ~why:(fun () ->
         Printf.sprintf "%d words for %d entries, %d each" grew entries
           per_entry)
       (* Thirty-two words apiece is the listing itself -- a record, a key and
          a cons -- plus the collector's headroom over it. A task apiece measured
          a hundred and fourteen, so the threshold sits between the two. *)
       (per_entry < 60);

     (* A listing is still a list, so the entries themselves are a real cost;
        what must not be there is the machinery that produced them. *)
     case "and the entries it returns are the only thing held";
     let live_before = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words in
     let+ held = B.list_prefix ~prefix:"objs/" () in
     let live = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words - live_before in
     check "what survives the call is the listing and no more"
       ~why:(fun () ->
         Printf.sprintf "%d words live for %d entries, %d each" live
           (List.length held) (live / entries))
       (live / entries < 20);
     Scratch.cleanup root;
     report ~expected:3 ())
