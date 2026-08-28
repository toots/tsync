(* Mount points are octal-escaped in the mount table, so a domain called
   "Jellyfin Media" arrives as "Jellyfin\040Media". *)
let unescape s =
  let buf = Buffer.create (String.length s) in
  let length = String.length s in
  let rec scan i =
    if i >= length then ()
    else if s.[i] = '\\' && i + 3 < length then (
      match int_of_string_opt ("0o" ^ String.sub s (i + 1) 3) with
        | Some code ->
            Buffer.add_char buf (Char.chr code);
            scan (i + 4)
        | None ->
            Buffer.add_char buf s.[i];
            scan (i + 1))
    else (
      Buffer.add_char buf s.[i];
      scan (i + 1))
  in
  scan 0;
  Buffer.contents buf

(* A mount table line is optional fields then " - ", so the filesystem type is
   found by the separator rather than by counting. [fuse.tsync] is the subtype
   libfuse takes from argv[0], which Fuse_fs passes as a constant: a fact about
   the running filesystem rather than anything the config could disagree with. *)
let mounted_paths mountinfo =
  match open_in mountinfo with
    | exception _ -> []
    | ic ->
        let rec after_separator = function
          | "-" :: fstype :: _ -> Some fstype
          | _ :: rest -> after_separator rest
          | [] -> None
        in
        let rec collect acc =
          match input_line ic with
            | exception End_of_file -> acc
            | line -> (
                match String.split_on_char ' ' line with
                  | _ :: _ :: _ :: _ :: mount :: rest
                    when after_separator rest = Some "fuse.tsync" ->
                      collect (unescape mount :: acc)
                  | _ -> collect acc)
        in
        let paths = collect [] in
        close_in ic;
        paths

let mount_points_in ~config_path ~mountinfo ~paths =
  let config = Conf_parsing.load config_path in
  let mounted = mounted_paths mountinfo in
  List.filter_map
    (fun (domain : Conf_parsing.domain) ->
      let mount = Conf_parsing.mount_point_of domain in
      if List.mem mount mounted then
        Some (mount, Runtime.domain_socket_path paths domain.Conf_parsing.name)
      else None)
    config.Conf_parsing.domains

(* Total by contract, not by luck: the caller is C, where an escaping exception
   takes the host process with it. *)
let mount_points () =
  try
    let paths = Runtime.default_paths () in
    mount_points_in ~config_path:paths.Runtime.config_path
      ~mountinfo:"/proc/self/mountinfo" ~paths
  with _ -> []
