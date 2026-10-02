open Tsync_core

type entry = {
  path : string;
  container : string;
  kind : [ `Dir | `File ];
  size : int;
  mtime : float;
}

let entry_json e =
  `Assoc
    ([
       ("path", `String e.path);
       ("container", `String e.container);
       ("kind", `String (match e.kind with `Dir -> "dir" | `File -> "file"));
     ]
    @
      match e.kind with
      | `Dir -> []
      | `File -> [("size", `Int e.size); ("mtime", `Float e.mtime)])

let header_of line =
  match Yojson.Safe.from_string line with
    | `Assoc f -> (
        match List.assoc_opt "walk" f with
          | Some (`String w) -> Some w
          | _ -> None)
    | _ | (exception _) -> None

let read_header file =
  match In_channel.with_open_bin file In_channel.input_line with
    | Some line -> header_of line
    | None | (exception Sys_error _) -> None

let all_digits s =
  s <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) s

(* A stamp other than the walk it replaces, so no cursor of the old walk reads
   the new one. *)
let stamp file =
  let now = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.) in
  match read_header file with
    | Some old when old = now ->
        Int64.to_string (Int64.succ (Int64.of_string old))
    | _ -> now

let write file ~skipped entries =
  let walk = stamp file in
  let b = Buffer.create 4096 in
  Buffer.add_string b
    (Yojson.Safe.to_string
       (`Assoc [("walk", `String walk); ("skipped", `Int skipped)]));
  Buffer.add_char b '\n';
  List.iter
    (fun e ->
      Buffer.add_string b (Yojson.Safe.to_string (entry_json e));
      Buffer.add_char b '\n')
    entries;
  Fs.mkdir_p (Filename.dirname file);
  Fs.replace file (Buffer.contents b);
  walk

let path_of_line line =
  match Yojson.Safe.from_string line with
    | `Assoc f -> (
        match List.assoc_opt "path" f with
          | Some (`String p) -> Some p
          | _ -> None)
    | _ | (exception _) -> None

(* 08 §2.5: the offset must start an entry line of the cursor's walk. *)
let page file ~cursor ~limit =
  match String.index_opt cursor ':' with
    | None -> `Stale
    | Some i ->
        let walk = String.sub cursor 0 i
        and off = String.sub cursor (i + 1) (String.length cursor - i - 1) in
        if not (all_digits walk && all_digits off) then `Stale
        else (
          match In_channel.open_bin file with
            | exception Sys_error _ -> `Stale
            | ic ->
                Fun.protect
                  ~finally:(fun () -> In_channel.close ic)
                  (fun () ->
                    match In_channel.input_line ic with
                      | Some header when header_of header = Some walk -> (
                          let first = Int64.of_int (String.length header + 1) in
                          let size = In_channel.length ic in
                          match Int64.of_string_opt off with
                            | Some o when o >= first && o <= size ->
                                In_channel.seek ic (Int64.pred o);
                                if In_channel.input_char ic <> Some '\n' then
                                  `Stale
                                else (
                                  let rec take n acc =
                                    if n = 0 then (List.rev acc, true)
                                    else (
                                      match In_channel.input_line ic with
                                        | Some l -> take (n - 1) (l :: acc)
                                        | None -> (List.rev acc, false))
                                  in
                                  let lines, full = take limit [] in
                                  let at = In_channel.pos ic in
                                  let next =
                                    if full && at < size then
                                      Some (walk ^ ":" ^ Int64.to_string at)
                                    else None
                                  in
                                  `Page
                                    (List.filter_map path_of_line lines, next))
                            | _ -> `Stale)
                      | _ -> `Stale))

let first_cursor file =
  match In_channel.with_open_bin file In_channel.input_line with
    | Some header -> (
        match header_of header with
          | Some walk ->
              Some (walk ^ ":" ^ string_of_int (String.length header + 1))
          | None -> None)
    | None | (exception Sys_error _) -> None
