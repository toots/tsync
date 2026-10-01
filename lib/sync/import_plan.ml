open Tsync_core

type entry =
  | Folder of string
  | File of { rel : string; path : string; size : int }
  | Link of { rel : string; path : string; target : string; size : int }

type outcome =
  | Imported of int
  | Skipped_exists
  | Skipped_symlink
  | Failed of string

type report = {
  imported : int;
  bytes : int;
  skipped : int;
  skipped_symlinks : int;
  failed : (string * string) list;
  cancelled : bool;
}

type plan = {
  entries : entry list;
  files : int;
  bytes : int;
  unreadable : string list;
}

let absolute p =
  let p =
    if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p
  in
  try Unix.realpath p with Unix.Unix_error _ -> p

let any globs path = List.exists (fun g -> Glob.matches g path) globs

(* A directory sorts with a trailing [/], so a walk visiting siblings in this
   order lists full paths in sort order. *)
let children path =
  let names = Sys.readdir path in
  Array.to_list names
  |> List.map (fun n ->
      let full = Filename.concat path n in
      let st = try Some (Unix.lstat full) with Unix.Unix_error _ -> None in
      let is_dir =
        match st with Some { st_kind = S_DIR; _ } -> true | _ -> false
      in
      ((if is_dir then n ^ "/" else n), n, full, st))
  |> List.sort (fun (a, _, _, _) (b, _, _, _) -> String.compare a b)

let link_size ~symlinks ~path ~target =
  match symlinks with
    | `Skip -> 0
    | `Keep -> String.length target
    | `Follow -> (
        match Unix.stat path with
          | { st_kind = S_REG; st_size; _ } -> st_size
          | _ | (exception Unix.Unix_error _) -> 0)

let plan ?(only = []) ?(exclude = []) ~symlinks src =
  let src = absolute src in
  let seen = Hashtbl.create 64 in
  let entries = ref [] and files = ref 0 and bytes = ref 0 in
  let unreadable = ref [] in
  let emit e = entries := e :: !entries in
  let keep_file size e =
    incr files;
    bytes := !bytes + size;
    emit e
  in
  (* [pending] holds the folders under [only] not yet planned, outermost
     first: they are planned once something beneath them is kept. *)
  let rec walk dir rel ~selected ~pending =
    match children dir with
      | exception Sys_error reason ->
          Log.warn "import: cannot list %s: %s; counted as empty" dir reason;
          unreadable := dir :: !unreadable;
          pending
      | entries_here ->
          List.fold_left
            (fun pending (_, name, full, st) ->
              let r = Names.join rel name in
              if any exclude r || any exclude name then pending
              else (
                let flush () =
                  List.iter (fun p -> emit (Folder p)) (List.rev pending);
                  []
                in
                match st with
                  | Some { Unix.st_kind = S_DIR; _ } ->
                      let real = try Unix.realpath full with _ -> full in
                      if Hashtbl.mem seen real then pending
                      else (
                        Hashtbl.replace seen real ();
                        let selected = selected || any only r in
                        if only = [] || selected then (
                          let pending = flush () in
                          emit (Folder r);
                          walk full r ~selected ~pending)
                        else (
                          let below =
                            walk full r ~selected ~pending:(r :: pending)
                          in
                          (* What [below] still holds of ours was never kept. *)
                          List.filter (fun p -> List.mem p pending) below))
                  | Some { st_kind = S_REG; st_size; _ } ->
                      if only = [] || selected || any only r then (
                        let pending = flush () in
                        keep_file st_size
                          (File { rel = r; path = full; size = st_size });
                        pending)
                      else pending
                  | Some { st_kind = S_LNK; _ } ->
                      if only = [] || selected || any only r then (
                        let target = try Unix.readlink full with _ -> "" in
                        let size = link_size ~symlinks ~path:full ~target in
                        let pending = flush () in
                        keep_file size
                          (Link { rel = r; path = full; target; size });
                        pending)
                      else pending
                  | _ -> pending))
            pending entries_here
  in
  Hashtbl.replace seen src ();
  ignore (walk src "" ~selected:false ~pending:[]);
  {
    entries = List.rev !entries;
    files = !files;
    bytes = !bytes;
    unreadable = List.rev !unreadable;
  }
