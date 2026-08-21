(* What an import holds while it walks, and what it may call a file.

   The listing is the tree's length, so holding it is a hundred megabytes of
   paths standing for the whole run before a byte is uploaded. Spilled instead,
   it is read back mapped — off the heap the collector walks — and what says so
   is live words when the first entry lands, divided by the entries there are.

   Spilling puts the names through a codec, which is the other half: a leaf name
   is an arbitrary byte string and a delimited record would corrupt exactly the
   one nobody has in their tree. *)

open Lwt.Syntax
open Check

let root = Filename.temp_dir "tsync-import-listing" ""
let src = Filename.concat root "src"
let conf = Fixture.conf ~domain:"listing" ~root ()

module C = (val conf : Conf.S)
module I = Import.Make (C)

let write rel =
  let path = Filename.concat src rel in
  ignore
    (Sys.command
       (Printf.sprintf "mkdir -p %s" (Filename.quote (Filename.dirname path))));
  let oc = open_out_bin path in
  output_string oc rel;
  close_out oc;
  rel

(* A folder marker must exist before anything names it as a parent, which is
   what the walk owes and what a sort of the folders alone would not say. *)
let parents_first dirs =
  let seen = Hashtbl.create 8 in
  List.for_all
    (fun d ->
      let parent = Filename.dirname d in
      let ok = parent = "." || Hashtbl.mem seen parent in
      Hashtbl.replace seen d ();
      ok)
    dirs

(* Every relative path the run reported, in the order it reported them. *)
let import ?(only = []) ?on_file:(hook = fun ~rel:_ ~n:_ -> ()) () =
  let order = ref [] in
  let dirs = ref [] in
  let n = ref 0 in
  let+ summary =
    I.run ~only ~src
      ~on_dir:(fun ~rel -> dirs := rel :: !dirs)
      ~on_file:(fun ~rel _ ->
        incr n;
        hook ~rel ~n:!n;
        order := rel :: !order)
      ()
  in
  (summary, List.rev !order, List.rev !dirs)

(* A tree whose names put the separator on the wrong side of a sort: '-' and '.'
   both precede '/', so a global sort of the paths interleaves the directory's
   contents with its siblings. *)
let ordering_tree = ["a-b.txt"; "a.txt"; "a/x.txt"; "a/b-c/d.txt"; "a/b/e.txt"]

(* What a delimited record would take for two entries, and a shell for four. *)
let awkward_tree =
  ["plain.txt"; "with\nnewline.txt"; "with\ttab.txt"; "dir\nbreak/inside.txt"]

let bulk = 2000

let () =
  Lwt_main.run
    (case "entries come out in the order a sort of every path gives";
     let planted = List.map write ordering_tree in
     let* _, order, dirs = import () in
     check "every file was reported once"
       ~why:(fun () -> String.concat ", " order)
       (List.sort compare order = List.sort compare planted);
     check "and in the order the whole tree sorts in"
       ~why:(fun () -> String.concat ", " order)
       (order = List.sort compare planted);
     check "a folder is announced before the folders under it"
       ~why:(fun () -> String.concat ", " dirs)
       (parents_first dirs);

     case "a name is an arbitrary byte string";
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote src)));
     let planted = List.map write awkward_tree in
     let* summary, order, _ = import () in
     check "a newline or a tab in a name survives the listing"
       ~why:(fun () -> String.concat " | " order)
       (List.sort compare order = List.sort compare planted);
     check "and every one of them imported"
       ~why:(fun () ->
         Printf.sprintf "%d imported, %d failed" summary.Import.imported
           summary.Import.failed)
       (summary.Import.imported = List.length planted
       && summary.Import.failed = 0);

     case "what the walk holds does not grow with the tree";
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote src)));
     let planted =
       List.init bulk (fun i ->
           write (Printf.sprintf "d%02d/f%05d" (i mod 20) i))
     in
     let live_at_first = ref 0 in
     let baseline = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words in
     let* summary, _, _ =
       import
         ~on_file:(fun ~rel:_ ~n ->
           if n = 1 then
             live_at_first :=
               (Stdlib.Gc.stat ()).Stdlib.Gc.live_words - baseline)
         ()
     in
     check "the fixture really is many files"
       (summary.Import.imported = List.length planted);
     (* Fewer words than there are files, which no per-entry retention reaches:
        a path and a cons cell apiece is several each, and rounding that to a
        per-file figure is how a check like this reads as passing. *)
     check "fewer live words when the first entry lands than the tree has files"
       ~why:(fun () ->
         Printf.sprintf "%d words for %d files" !live_at_first bulk)
       (!live_at_first < bulk);

     (* [only] is applied as the walk goes, so a branch it does not select is
        never written down, and the folders that are come from the entries
        beneath them rather than from a second pass. *)
     case "only selects as the walk goes";
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote src)));
     let _ = List.map write ["keep/a.txt"; "keep/deep/b.txt"; "drop/c.txt"] in
     let+ _, order, dirs = import ~only:["keep"] () in
     check "only what was selected is imported"
       ~why:(fun () -> String.concat ", " order)
       (order = ["keep/a.txt"; "keep/deep/b.txt"]);
     check "and only the folders holding it get a marker"
       ~why:(fun () -> String.concat ", " dirs)
       (dirs = ["keep"; "keep/deep"]);
     report ~expected:9 ())
