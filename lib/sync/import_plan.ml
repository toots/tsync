open Tsync_core

type entry =
  | Folder of string
  | File of { rel : string; path : string; size : int; times : Fs.times option }
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
  uncommitted : int;
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
              else if Names.is_reserved r then (
                Log.warn "import: %s skipped, the name is reserved (01 §2.3)"
                  full;
                pending)
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
                          (File
                             {
                               rel = r;
                               path = full;
                               size = st_size;
                               times = None;
                             });
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

let nanoseconds s =
  if s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s then
    int_of_string_opt s
  else None

let map_line ~base ~file n line =
  let invalid fmt = Fail.invalid ("%s:%d: " ^^ fmt) file n in
  let local, domain, times =
    match String.split_on_char '\t' line with
      | [local; domain] -> (local, domain, None)
      | [local; domain; mtime; created] -> (
          match (nanoseconds mtime, nanoseconds created) with
            | Some mtime, Some created ->
                ( local,
                  domain,
                  Some { Fs.mtime; created = Fs.creation ~mtime created } )
            | _ -> invalid "times are not integers")
      | _ -> invalid "expected 2 or 4 tab-separated fields"
  in
  let rel =
    try Names.user_path domain
    with Fail.E _ -> invalid "invalid path %S" domain
  in
  if rel = "" then invalid "the domain root is not a file";
  if Names.is_reserved rel then invalid "%S is reserved" rel;
  let path =
    if Filename.is_relative local then Filename.concat base local else local
  in
  let size =
    match Unix.LargeFile.stat path with
      | { st_size; _ } -> Int64.to_int st_size
      | exception Unix.Unix_error _ -> 0
  in
  File { rel; path; size; times }

let of_map ~base file =
  let base = absolute base in
  let lines =
    (try In_channel.with_open_bin file In_channel.input_lines
     with Sys_error reason -> Fail.invalid "cannot read the map: %s" reason)
    |> List.map (fun l ->
        if String.ends_with ~suffix:"\r" l then
          String.sub l 0 (String.length l - 1)
        else l)
    |> List.mapi (fun i l -> (i + 1, l))
    |> List.filter (fun (_, l) -> String.trim l <> "")
  in
  let files = List.map (fun (n, l) -> map_line ~base ~file n l) lines in
  let rels = Hashtbl.create 1024 and folders = Hashtbl.create 256 in
  List.iter
    (function
      | File { rel; _ } ->
          if Hashtbl.mem rels rel then
            Fail.invalid "%s: %S is mapped twice" file rel;
          Hashtbl.replace rels rel ();
          let rec up p =
            let p = Names.parent_of p in
            if p <> "" && not (Hashtbl.mem folders p) then (
              Hashtbl.replace folders p ();
              up p)
          in
          up rel
      | _ -> ())
    files;
  Hashtbl.iter
    (fun f () ->
      if Hashtbl.mem rels f then
        Fail.invalid "%s: %S is mapped as a file and holds others" file f)
    folders;
  let folders =
    Hashtbl.to_seq_keys folders |> List.of_seq |> List.sort String.compare
  in
  {
    entries = List.map (fun f -> Folder f) folders @ files;
    files = List.length files;
    bytes =
      List.fold_left
        (fun acc -> function File { size; _ } -> acc + size | _ -> acc)
        0 files;
    unreadable = [];
  }
