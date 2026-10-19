(* format-merge: a folder and its conflicted copies settled after an arrival,
   by the format that applies to it, and the one runner every fold goes
   through. *)
open Tsync_core
open Tsync_sync

let write_file (module E : Engine.S) ~exclusive path body =
  E.create path ~exclusive;
  E.truncate path 0;
  E.write path ~off:0 (Bigstring.of_string body);
  E.close path

(* §3: a fold's actions run in order and stop at the first failure, so a copy is
   never removed after what should have absorbed it failed to be written; what
   is left settles at the next trigger. Whether every action ran. *)
let apply engine dir actions =
  let (module E : Engine.S) = engine in
  try
    List.iter
      (function
        | Tsync_vault.Fold.Move { src; dst } ->
            E.rename ~src:(Names.join dir src) ~dst:(Names.join dir dst)
              ~exclusive:false
        | Remove name -> E.delete (Names.join dir name)
        | Write { name; body } ->
            write_file engine ~exclusive:false (Names.join dir name) body)
      actions;
    true
  with Fail.E f ->
    Log.warn "format merge: a fold in %s is left: %s" dir f.reason;
    false

(* §6: one settling of a folder at a time, a verb's or an arrival's: two at
   once would remove a copy the other is reading.
   ponytail: one table for every domain, which serialises two domains' folders
   of one name; key by domain if that ever waits. *)
let folders = Keyed_locks.create ()
let locked dir f = Keyed_locks.with_key folders dir f

(* §3 a fold: the folder's files, folded, applied, then the format's writes
   after a complete fold (a relabel); the files as they stand after. *)
let settle_folder ?(after = fun _ -> ()) ~read ~fold engine dir =
  locked dir (fun () ->
      let files = read () in
      match fold files with
        | [] -> files
        | actions ->
            if apply engine dir actions then List.iter after actions;
            read ())

type format = {
  name : string;
  folder : string;  (** the folder it applies to (§4) *)
  settle : unit -> unit;
      (** raises [Fail.E] when it cannot run yet (§2 rule 3) *)
}

type t = {
  formats : format list Atomic.t;
  running : (string, unit) Hashtbl.t;
  m : Mutex.t;
}

let create () =
  { formats = Atomic.make []; running = Hashtbl.create 4; m = Mutex.create () }

let register t format = Atomic.set t.formats (format :: Atomic.get t.formats)

(* ponytail: the conflicted-copy name is parsed by the vault's fold, the one
   reader of it; move it to the merge's module when a second format needs it. *)
let is_copy path = Tsync_vault.Fold.copied_from (Names.leaf_of path) <> None

(* §2 rule 1: in the background, one settling per folder at a time; a format
   that cannot run yet waits for its next trigger. *)
let arrived t ~spawn paths =
  let folders =
    List.sort_uniq compare
      (List.map Names.parent_of (List.filter is_copy paths))
  in
  List.iter
    (fun (format : format) ->
      if
        List.mem format.folder folders
        && Mutex.protect t.m (fun () ->
            if Hashtbl.mem t.running format.folder then false
            else (
              Hashtbl.replace t.running format.folder ();
              true))
      then
        spawn (fun () ->
            Fun.protect
              ~finally:(fun () ->
                Mutex.protect t.m (fun () ->
                    Hashtbl.remove t.running format.folder))
              (fun () ->
                try format.settle ()
                with Fail.E f ->
                  Log.info "format merge %s: %s is left for later: %s"
                    format.name format.folder f.reason)))
    (Atomic.get t.formats)
