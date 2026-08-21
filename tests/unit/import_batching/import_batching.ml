(* How an import splits its ops across published journal entries.

   A deferred replica queues an entry behind the objects it names, so a run
   covered by one terminal entry stays invisible to that replica's readers
   until its whole backlog drains. Splitting only helps if the pieces stay
   replayable: a peer resolves a file's folder by the id its marker carries, so
   the assertions here are that no put is published before the mkdir naming its
   folder, and that the pieces still add up to the run. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "import-batching"
let src = Filename.concat root "src"
let main_dir = Filename.concat root "main"
let entry_ops = 2

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(Fixture.local_store main_dir)
         ~root ()
      : Conf.S)

module I = Import.Make (C)
module Fs = File_store.Make (C)

let write rel =
  let path = Filename.concat src rel in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.dirname path)));
  let oc = open_out_bin path in
  output_string oc rel;
  close_out oc;
  rel

(* The published entries in the order a peer replays them. *)
let list_entries () =
  let* keys = Fs.list_journal_keys () in
  Lwt_list.filter_map_s
    (fun key ->
      let+ ops = Fs.get_journal_entry key in
      Option.map (fun ops -> (key, ops)) ops)
    keys

let put_of = function `Put (rel, _) -> Some rel | _ -> None
let mkdir_of = function `Mkdir (rel, _) -> Some rel | _ -> None

let () =
  Lwt_main.run
    (let files =
       List.map write
         [
           "a.txt";
           "keep/b.txt";
           "keep/c.txt";
           "keep/deep/d.txt";
           "keep/deep/e.txt";
           "other/f.txt";
         ]
     in
     let* (_ : Import.summary) =
       I.run ~entry_ops ~src ~on_file:(fun ~rel:_ _ -> ()) ()
     in
     let* entries = list_entries () in
     let ops = List.concat_map snd entries in
     let puts = List.filter_map put_of ops in
     let mkdirs = List.filter_map mkdir_of ops in

     case "the run is split rather than published as one entry";
     check
       (Printf.sprintf "%d files and %d folders came out as %d entries"
          (List.length files) (List.length mkdirs) (List.length entries))
       (List.length entries > 1);
     check "and no entry carries more than the cap"
       ~why:(fun () ->
         String.concat ", "
           (List.map (fun (_, ops) -> string_of_int (List.length ops)) entries))
       (List.for_all (fun (_, ops) -> List.length ops <= entry_ops) entries);

     case "the pieces still add up to the run";
     check "every imported file is published exactly once"
       ~why:(fun () -> String.concat ", " (List.sort compare puts))
       (List.sort compare puts = List.sort compare files);
     check "and every folder it created is too"
       ~why:(fun () -> String.concat ", " (List.sort compare mkdirs))
       (List.sort compare mkdirs
       = List.sort compare ["keep/"; "keep/deep/"; "other/"]);

     case "a folder is named before anything is put in it";
     let first_put =
       let rec go i = function
         | [] -> max_int
         | (_, ops) :: rest ->
             if List.exists (fun op -> put_of op <> None) ops then i
             else go (i + 1) rest
       in
       go 0 entries
     in
     let last_mkdir =
       let rec go i last = function
         | [] -> last
         | (_, ops) :: rest ->
             go (i + 1)
               (if List.exists (fun op -> mkdir_of op <> None) ops then i
                else last)
               rest
       in
       go 0 (-1) entries
     in
     check
       (Printf.sprintf "the last mkdir entry (%d) precedes the first put (%d)"
          last_mkdir first_put)
       (last_mkdir < first_put);

     case "a reader is pointed at the whole run";
     let* cursor = Fs.fetch_cursor () in
     let last = fst (List.nth entries (List.length entries - 1)) in
     check "the cursor names the last entry published"
       (Option.map Journal.Entry_key.to_string cursor
       = Some (Journal.Entry_key.to_string last));

     case "a long run publishes before it ends";
     (* [entry_ops] out of reach, so only the age bound can split this. *)
     let src2 = Filename.concat root "src2" in
     let files2 =
       List.map
         (fun rel ->
           let path = Filename.concat src2 rel in
           ignore
             (Sys.command
                (Printf.sprintf "mkdir -p %s" (Filename.dirname path)));
           let oc = open_out_bin path in
           output_string oc rel;
           close_out oc;
           rel)
         ["g.txt"; "h.txt"; "i.txt"]
     in
     let before = List.length entries in
     let* (_ : Import.summary) =
       I.run ~entry_ops:max_int ~entry_age:0. ~src:src2
         ~on_file:(fun ~rel:_ _ -> ())
         ()
     in
     let+ all = list_entries () in
     let added = List.length all - before in
     check
       (Printf.sprintf
          "%d files under an unreachable op cap came out as %d entries"
          (List.length files2) added)
       (added > 1);

     report ~expected:7 ())
