let sentinel = ".tsync-esc-"
let dir_marker = ".tsync-name"

(* NAME_MAX is 255 bytes on the targeted filesystems; the margin leaves room for
   any suffix appended to a stored leaf. *)
let name_max = 250
let hash c = Xxhash.hash_hex c 0
let is_escaped name = String.starts_with ~prefix:sentinel name

(* Illegal in a filename component on FAT/exFAT/NTFS, plus control characters.
   Escaped even where the local filesystem would accept them. *)
let is_portable_char = function
  | '"' | '*' | ':' | '<' | '>' | '?' | '\\' | '|' -> false
  | c when Char.code c < 32 -> false
  | _ -> true

let representable c =
  String.length c <= name_max
  && (not (String.starts_with ~prefix:sentinel c))
  && String.for_all is_portable_char c

let encode_component c = if representable c then c else sentinel ^ hash c

let encode_key rel =
  String.split_on_char '/' rel |> List.map encode_component |> String.concat "/"

(* The two bookkeeping files a local tree keeps beside its manifests. The folder
   marker's name lives here rather than with {!Folder_ids} so that reading a
   directory entry needs only this module. *)
let folder_marker = ".tsync-dir"

let is_internal name =
  Fs_util.is_temp_name name || name = dir_marker || name = folder_marker

(* Records an escaped directory's real name so readdir can recover it. *)
let write_marker path name =
  let open Lwt.Syntax in
  let* exists = Lwt_unix_retry.file_exists path in
  if exists then Lwt.return_unit else Fs_util.atomic_write path name

let read_marker path =
  let open Lwt.Syntax in
  let+ body = Fs_util.read_file_opt path in
  Option.value body ~default:""

let real_dir_name dir_path name =
  if is_escaped name then read_marker (Filename.concat dir_path dir_marker)
  else Lwt.return name
