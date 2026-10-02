open Tsync_core

let subtype_chars s =
  if
    String.for_all
      (fun c ->
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '.' || c = '_' || c = '-')
      s
  then None
  else Some "only letters, digits, '.', '_' and '-'"

let is_decimal s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

(* The kernel's ids are 32 bits wide, and the all-ones id means "none". *)
let max_id = 0xFFFF_FFFE

let resolve lookup name =
  if is_decimal name then
    Option.bind (int_of_string_opt name) (fun id ->
        if id <= max_id then Some id else None)
  else (match lookup name with id -> Some id | exception Not_found -> None)

let user_id = resolve (fun name -> (Unix.getpwnam name).pw_uid)
let group_id = resolve (fun name -> (Unix.getgrnam name).gr_gid)

let known what id name =
  match id name with
    | Some _ -> None
    | None when is_decimal name ->
        Some (Printf.sprintf "a decimal id is at most %d" max_id)
    | None -> Some ("no such " ^ what)

let mode s =
  let digits =
    if String.length s = 4 && s.[0] = '0' then String.sub s 1 3 else s
  in
  if
    String.length digits = 3
    && String.for_all (fun c -> c >= '0' && c <= '7') digits
  then Some (int_of_string ("0o" ^ digits))
  else None

let mode_digits s =
  match mode s with
    | Some _ -> None
    | None -> Some "three octal digits, optionally after a leading 0"

let fields =
  Field_spec.
    [
      f ~check:absolute_path "mountPoint" "Mount point" Path;
      f ~default:"false" "allowOther" "Allow other users" Bool;
      f ~check:(known "user" user_id) "uid" "Owner reported for every entry"
        String;
      f ~check:(known "group" group_id) "gid" "Group reported for every entry"
        String;
      f ~default:"0644" ~check:mode_digits "fileMode" "Mode reported for files"
        String;
      f ~default:"0755" ~check:mode_digits "dirMode"
        "Mode reported for directories" String;
      f ~default:"sshfs" ~check:subtype_chars "mountSubtype" "Mount subtype"
        String;
    ]

let () =
  Tsync_config.Frontend.register "fuse"
    {
      fields;
      presenting = Some `Per_domain;
      commands_only = None;
      group = None;
      commands = [];
    }
