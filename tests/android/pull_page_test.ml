(* android §3.2: a pull reads and merges the log a page at a time, so a pull
   cut short keeps the pages it merged. *)

open Tsync_android
open Lazy_harness

let names j =
  match field j "items" with
    | Some (`List items) ->
        String.concat ", " (List.map (fun i -> text i "name") items)
    | _ -> outcome j

let () =
  setup ();
  peer_does (fun (module E) -> E.mkdir "sub" ~exclusive:true);
  peer_writes "sub/a" "a";
  p "  %-34s %S" "boot, a page of 4 entries"
    (Android_host.boot
       ~pull_params:
         {
           pull_freshness = fresh_window;
           view_max_age = 3600.;
           pull_patience = 30.;
           refresh_patience = 20.;
           pull_page = 4;
         }
       "");
  let sub = ref_of (list "root" "root") "sub" in
  ignore (list "sub" sub);

  p "== ten commits, then the store fails after six entry reads";
  List.iter
    (fun i -> peer_writes (Printf.sprintf "sub/f%02d" i) "f")
    (List.init 10 Fun.id);
  wait_stale ();
  Atomic.set entry_reads_left (Some 6);
  p "  %-34s %s" "pull"
    (outcome (action "list_dir" [s "ref" sub; s "pull" "now"]));
  Atomic.set entry_reads_left None;
  p "  %-34s [%s]" "kept from the first page"
    (names (action "list_dir" [s "ref" sub; s "pull" "never"]));

  p "== the store returns";
  p "  %-34s [%s]" "pull"
    (names (action "list_dir" [s "ref" sub; s "pull" "now"]))
