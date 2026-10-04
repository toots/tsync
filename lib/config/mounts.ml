open Tsync_core

let configured (d : Config.domain) =
  Option.map
    (fun (f : Config.frontend) ->
      match Config.fstr f.options "mountPoint" with
        | Some m -> m
        | None -> Paths.mount_point d.name)
    (Config.frontend d "fuse")

let holding (config : Config.t) path =
  List.filter_map
    (fun (d : Config.domain) ->
      Option.bind (configured d) (fun mount ->
          let n = String.length mount in
          if path = mount then Some (n, (d, ""))
          else if String.starts_with ~prefix:(mount ^ "/") path then
            Some (n, (d, String.sub path (n + 1) (String.length path - n - 1)))
          else None))
    config.domains
  |> List.sort (fun (a, _) (b, _) -> compare b a)
  |> function
  | (_, held) :: _ -> Some held
  | [] -> None

let decode s =
  let n = String.length s in
  let b = Buffer.create n in
  let octal i = i < n && s.[i] >= '0' && s.[i] <= '7' in
  let rec go i =
    if i < n then
      if s.[i] = '\\' && octal (i + 1) && octal (i + 2) && octal (i + 3) then (
        let v = int_of_string ("0o" ^ String.sub s (i + 1) 3) in
        if v <= 255 then (
          Buffer.add_char b (Char.chr v);
          go (i + 4))
        else (
          Buffer.add_char b '\\';
          go (i + 1)))
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

let mounted table =
  let rec after_separator = function
    | "-" :: fstype :: source :: _ -> Some (fstype, source)
    | _ :: rest -> after_separator rest
    | [] -> None
  in
  List.filter_map
    (fun line ->
      match String.split_on_char ' ' line with
        | _ :: _ :: _ :: _ :: mount_point :: rest -> (
            match after_separator rest with
              | Some (fstype, "tsync")
                when String.starts_with ~prefix:"fuse." fstype ->
                  Some (decode mount_point)
              | _ -> None)
        | _ -> None)
    (String.split_on_char '\n' table)

let components path =
  List.filter (fun c -> c <> "" && c <> ".") (String.split_on_char '/' path)

let max_links = 40

let resolve ~stops parents =
  let rec walk resolved rest links =
    match rest with
      | [] -> Some resolved
      | ".." :: rest -> walk (Filename.dirname resolved) rest links
      | c :: rest ->
          let next = Filename.concat resolved c in
          if List.mem next stops then Some (String.concat "/" (next :: rest))
          else (
            match Unix.lstat next with
              | { st_kind = S_LNK; _ } when links > 0 ->
                  let target = Unix.readlink next in
                  walk
                    (if Filename.is_relative target then resolved else "/")
                    (components target @ rest)
                    (links - 1)
              | { st_kind = S_LNK; _ } -> None
              | _ -> walk next rest links
              | exception Unix.Unix_error _ -> None)
  in
  walk "/" parents max_links

let canonical ~stops path =
  match List.rev (components path) with
    | [] -> path
    | leaf :: parents -> (
        match resolve ~stops (List.rev parents) with
          | Some parent -> Filename.concat parent leaf
          | None -> path)

let mount_points ?(table = "/proc/self/mountinfo") () =
  try
    let mounted = mounted (Option.value ~default:"" (Fs.read_file_opt table)) in
    match Paths.read_config ~interactive:false () with
      | None -> []
      | Some text ->
          List.filter_map
            (fun (d : Config.domain) ->
              Option.bind (configured d) (fun mount_point ->
                  let mount_point = canonical ~stops:mounted mount_point in
                  if List.mem mount_point mounted then
                    Some (mount_point, Paths.owner_socket d.name)
                  else None))
            (Config.of_string text).domains
  with _ -> []
