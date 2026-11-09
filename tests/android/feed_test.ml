(* android §6: the change feed and the whole-domain listing on a pulled tree,
   over the held folders only. *)

open Tsync_android
open Lazy_harness

let reads f =
  let before = Atomic.get listings in
  let j = f () in
  (j, if Atomic.get listings > before then "read the store" else "no read")

let show_all label =
  let j, read = reads (fun () -> action "list_all" []) in
  match field j "items" with
    | Some (`List items) ->
        p "  %-34s [%s] %s" label (String.concat ", " (List.map row items)) read
    | _ -> p "  %-34s %s, %s" label (outcome j) read

let op j =
  Printf.sprintf "%s %s in %s" (text j "op") (text j "name")
    (scrub_ref (text j "parentRef"))

(* The ops after [anchor], and the anchor after them. *)
let changes label anchor =
  let j = action "changes_since" [s "arg" anchor] in
  match field j "ops" with
    | Some (`List ops) ->
        p "  %-34s [%s]" label (String.concat ", " (List.map op ops));
        text j "cursor"
    | _ ->
        p "  %-34s %s" label (outcome j);
        anchor

let () =
  setup ();
  peer_writes "a.txt" "a";
  peer_does (fun (module E) -> E.mkdir "sub" ~exclusive:true);
  peer_writes "sub/deep.txt" "deep";
  peer_does (fun (module E) -> E.mkdir "other" ~exclusive:true);
  peer_writes "other/x.txt" "x";
  p "  %-34s %S" "boot"
    (Android_host.boot
       ~pull_params:
         {
           pull_freshness = fresh_window;
           view_max_age = 3600.;
           pull_patience = 30.;
           pull_page = 256;
         }
       "");

  p "== the phone holds root and sub, not other";
  let root = list "root" "root" in
  ignore (list "sub" (ref_of root "sub"));
  let anchor = text (action "cursor" []) "cursor" in
  show_all "list_all";

  p "== a peer changes held and unheld folders";
  peer_writes "sub/new.txt" "new";
  peer_writes "other/y.txt" "y";
  peer_does (fun (module E) -> E.delete "a.txt");
  let anchor = changes "before any pull" anchor in
  wait_stale ();
  ignore (list "root" "root");
  ignore (list "sub" (ref_of root "sub"));
  let anchor = changes "after pulling root and sub" anchor in

  p "== a change of the phone's own";
  p "  %-34s %s" "mkdir mine"
    (outcome (action "mkdir" [s "parentRef" "root"; s "name" "mine"]));
  let mine =
    text (action "stat" [s "parentRef" "root"; s "name" "mine"]) "ref"
  in
  p "  %-34s %s" "write in mine"
    (outcome
       (action "write"
          [
            s "parentRef" mine;
            s "name" "own.txt";
            s "staging" (staged "own.txt" "own");
          ]));
  ignore (changes "after mkdir and write" anchor);
  show_all "list_all again"
