(* android §3.2: what one refresh pass costs against the number of held
   folders, with one changed. Not a snapshot: it prints times. *)

open Tsync_android
open Lazy_harness

let n = try int_of_string Sys.argv.(1) with _ -> 5000
let folders = List.init n (Printf.sprintf "many/f%05d")
let freshness = 1.

let () =
  setup ();
  peer_does (fun (module E) ->
      E.mkdir "many" ~exclusive:true;
      List.iter (fun f -> E.mkdir f ~exclusive:true) folders;
      E.drain ~grace:600. ());
  ignore
    (Android_host.boot
       ~pull_params:
         {
           pull_freshness = freshness;
           view_max_age = 3600.;
           pull_patience = 30.;
           refresh_patience = 600.;
           pull_page = 256;
         }
       "");
  let t0 = Unix.gettimeofday () in
  let root = action "list_dir" [s "ref" "root"; s "pull" "now"] in
  let many = ref_of root "many" in
  let rec pages after =
    let j =
      action "list_dir"
        (s "ref" many :: s "pull" "now"
        :: (match after with Some a -> [s "after" a] | None -> []))
    in
    let items = match field j "items" with Some (`List l) -> l | _ -> [] in
    match field j "next" with
      | Some (`String next) -> items @ pages (Some next)
      | _ -> items
  in
  let rec all tries =
    let items = pages None in
    if List.length items >= n || tries = 0 then items
    else (
      Thread.delay 1.;
      all (tries - 1))
  in
  let items = all 60 in
  List.iter (fun i -> ignore (action "list_dir" [s "ref" (text i "ref")])) items;
  p "held %d folders in %.1f s" (n + 1) (Unix.gettimeofday () -. t0);
  let changes anchor =
    match field (action "changes_since" [s "arg" anchor]) "ops" with
      | Some (`List ops) ->
          String.concat ", "
            (List.map (fun j -> text j "op" ^ " " ^ text j "name") ops)
      | _ -> "none"
  in
  if Array.length Sys.argv > 2 && Sys.argv.(2) = "outage" then (
    Atomic.set mode `Down;
    for _ = 1 to 3 do
      Thread.delay (freshness +. 0.1);
      p "refresh with the store down: %s" (outcome (action "refresh" []));
      ignore (action "list_dir" [s "ref" "root"; s "pull" "now"])
    done;
    Atomic.set mode `Up;
    p "store back up");
  List.iteri
    (fun i path ->
      let anchor = text (action "cursor" []) "cursor" in
      if String.ends_with ~suffix:"/" path then
        peer_does (fun (module E) ->
            E.mkdir (String.sub path 0 (String.length path - 1)) ~exclusive:true)
      else peer_writes path "x";
      Thread.delay (freshness +. 0.1);
      let reads = Atomic.get entry_reads in
      let t0 = Unix.gettimeofday () in
      ignore (action "refresh" []);
      p "pass %d (%s): %.3f s, %d log entries read, changes [%s]" (i + 1) path
        (Unix.gettimeofday () -. t0)
        (Atomic.get entry_reads - reads)
        (changes anchor))
    [
      Printf.sprintf "many/f%05d/new.txt" (n / 2);
      "many/push-b22.txt";
      "push-test/";
      "top.txt";
    ]
