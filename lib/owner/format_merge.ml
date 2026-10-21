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
   is left settles at the next trigger. The actions that ran. *)
let apply engine dir actions =
  let (module E : Engine.S) = engine in
  let rec go ran = function
    | [] -> List.rev ran
    | action :: rest -> (
        match
          match action with
            | Tsync_vault.Fold.Move { src; dst } ->
                E.rename ~src:(Names.join dir src) ~dst:(Names.join dir dst)
                  ~exclusive:false
            | Remove name -> E.delete (Names.join dir name)
            | Write { name; body } ->
                write_file engine ~exclusive:false (Names.join dir name) body
        with
          | () -> go (action :: ran) rest
          | exception Fail.E f ->
              Log.warn "format merge: a fold in %s is left: %s" dir f.reason;
              List.rev ran)
  in
  go [] actions

(* §6: one writer of a folder at a time, a settling or a verb that reads then
   writes it. Not reentrant: a caller takes each folder once, an extension's
   before the vault's.
   ponytail: one table for every domain, which serialises two domains' folders
   of one name; key by domain if that ever waits. *)
let folders = Keyed_locks.create ()
let locked dir f = Keyed_locks.with_key folders dir f

(* ponytail: the conflicted-copy name is parsed by the vault's fold, the one
   reader of it; move it to the merge's module when a second shape needs it. *)
let is_copy path = Tsync_vault.Fold.copied_from (Names.leaf_of path) <> None

(* §2: told by the names alone. *)
let has_copies (module E : Engine.S) dir =
  E.kind dir = `Dir
  && List.exists
       (fun (e : E.entry) -> (not e.is_dir) && is_copy e.name)
       (E.list_children dir)

(* §3 a fold, under the folder's lock the caller holds: the folder's files,
   folded, applied, then the format's writes for each action that ran (a
   relabel); [None] when no file is a copy, nothing read (§2). Nothing is
   applied on a domain this client may not write. *)
let settle_folder ?(after = fun _ -> ()) ~writable ~read ~fold engine dir =
  if not (has_copies engine dir) then None
  else (
    let files = read () in
    match fold files with
      | [] -> Some files
      | _ when not writable -> Some files
      | actions ->
          List.iter after (apply engine dir actions);
          Some (read ()))

type format = {
  name : string;
  folder : string;  (** the folder it applies to (§4) *)
  settle : unit -> unit;
      (** takes its locks; raises [Fail.E] when it cannot run yet (§2 rule 3) *)
}

type state = Running | Again

type t = {
  formats : format list Atomic.t;
  running : (string, state) Hashtbl.t;
  m : Mutex.t;
}

let create () =
  { formats = Atomic.make []; running = Hashtbl.create 4; m = Mutex.create () }

let register t format = Atomic.set t.formats (format :: Atomic.get t.formats)

let registered_folders t =
  List.map (fun (f : format) -> f.folder) (Atomic.get t.formats)

(* Whether this call starts the folder's settling; one already running is
   asked to go again (§2 rule 1). *)
let claim t dir =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.running dir with
        | Some _ ->
            Hashtbl.replace t.running dir Again;
            false
        | None ->
            Hashtbl.replace t.running dir Running;
            true)

(* Whether another arrival came during the settling that just ended. *)
let again t dir =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.running dir with
        | Some Again ->
            Hashtbl.replace t.running dir Running;
            true
        | _ ->
            Hashtbl.remove t.running dir;
            false)

let settle_once (format : format) =
  try format.settle ()
  with Fail.E f ->
    Log.info "format merge %s: %s is left for later: %s" format.name
      format.folder f.reason

(* §2 rule 1: the copies among [paths] still there schedule their folders, in
   the background. *)
let arrived t ~present ~spawn paths =
  let folders =
    List.sort_uniq compare
      (List.map Names.parent_of
         (List.filter (fun p -> is_copy p && present p) paths))
  in
  List.iter
    (fun (format : format) ->
      if List.mem format.folder folders && claim t format.folder then
        spawn (fun () ->
            let rec loop () =
              settle_once format;
              if again t format.folder then loop ()
            in
            Fun.protect
              ~finally:(fun () ->
                Mutex.protect t.m (fun () ->
                    Hashtbl.remove t.running format.folder))
              loop))
    (Atomic.get t.formats)
