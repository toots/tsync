let is_hexlower c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
let all_hex s = s <> "" && String.for_all is_hexlower s

let valid_segment s =
  s <> "" && s <> "." && s <> ".."
  && not (String.contains s '/' || String.contains s '\000')

let valid_key s =
  s <> ""
  && s.[0] <> '/'
  && s.[String.length s - 1] <> '/'
  && List.for_all valid_segment (String.split_on_char '/' s)

let valid_prefix s =
  s = ""
  || String.length s >= 2
     && s.[String.length s - 1] = '/'
     && valid_key (String.sub s 0 (String.length s - 1))

let check_key ?(op = "") k =
  if not (valid_key k) then Fail.invalid ~op "invalid key %S" k

let check_prefix ?(op = "") p =
  if not (valid_prefix p) then Fail.invalid ~op "invalid prefix %S" p

let reserved_roots = ["shares"; "corrupted"; "verify-jobs"; "gc-jobs"]

let domain_name_error ?(local_store = false) s =
  let n = String.length s in
  if n = 0 || n > 255 then Some "a domain name has 1 to 255 bytes"
  else if s = "." || s = ".." then Some "a domain name cannot be . or .."
  else if
    String.exists
      (fun c -> c = '/' || Char.code c < 0x20 || Char.code c = 0x7f)
      s
  then Some "a domain name cannot contain '/' or control characters"
  else if String.starts_with ~prefix:".tsync-" s then
    Some "a domain name cannot begin with .tsync-"
  else if List.mem s reserved_roots then
    Some (Printf.sprintf "%S is a reserved name" s)
  else if local_store && List.mem (String.lowercase_ascii s) reserved_roots then
    Some (Printf.sprintf "%S is a reserved name on a local-filesystem store" s)
  else None

let valid_domain_name ?local_store s = domain_name_error ?local_store s = None
let valid_leaf = valid_segment

let valid_path p =
  p = "" || List.for_all valid_leaf (String.split_on_char '/' p)

let user_path p =
  let p =
    if String.starts_with ~prefix:"/" p then String.sub p 1 (String.length p - 1)
    else p
  in
  let p =
    if String.ends_with ~suffix:"/" p then String.sub p 0 (String.length p - 1)
    else p
  in
  if valid_path p then p else Fail.invalid "invalid path %S" p

let root_id = ".tsync-root"
let trash_id = ".tsync-trash"

let valid_hex_id s =
  match String.index_opt s '-' with
    | None -> all_hex s
    | Some i ->
        all_hex (String.sub s 0 i)
        && all_hex (String.sub s (i + 1) (String.length s - i - 1))

let valid_folder_id s = s = root_id || s = trash_id || valid_hex_id s

let is_chunk_key s =
  String.length s = 33
  && s.[16] = '-'
  && String.for_all is_hexlower (String.sub s 0 16)
  && String.for_all is_hexlower (String.sub s 17 16)

let shard key = if String.length key < 3 then "_" else String.sub key 0 3
let valid_shard s = String.length s = 3 && String.for_all is_hexlower s

let leaf_of p =
  match String.rindex_opt p '/' with
    | None -> p
    | Some i -> String.sub p (i + 1) (String.length p - i - 1)

let parent_of p =
  match String.rindex_opt p '/' with None -> "" | Some i -> String.sub p 0 i

let join a b = if a = "" then b else if b = "" then a else a ^ "/" ^ b

let is_under ~dir p =
  dir = "" || p = dir || String.starts_with ~prefix:(dir ^ "/") p

type item_ref =
  | Root
  | Dir of string
  | File_id of string
  | File of string * string

let valid_file_id s =
  String.length s = 32
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let parse_ref s =
  if s = "root" then Ok Root
  else if String.starts_with ~prefix:"d:" s then (
    let id = String.sub s 2 (String.length s - 2) in
    if id = root_id then Ok Root
    else if valid_folder_id id && id <> trash_id then Ok (Dir id)
    else Error ())
  else if String.starts_with ~prefix:"i:" s then (
    let id = String.sub s 2 (String.length s - 2) in
    if valid_file_id id then Ok (File_id id) else Error ())
  else if String.starts_with ~prefix:"f:" s then (
    let rest = String.sub s 2 (String.length s - 2) in
    match String.index_opt rest '/' with
      | None -> Error ()
      | Some i ->
          let id = String.sub rest 0 i
          and leaf = String.sub rest (i + 1) (String.length rest - i - 1) in
          if valid_folder_id id && id <> trash_id && valid_leaf leaf then
            Ok (File (id, leaf))
          else Error ())
  else Error ()

let ref_to_string = function
  | Root -> "root"
  | Dir id -> "d:" ^ id
  | File_id id -> "i:" ^ id
  | File (id, leaf) -> "f:" ^ id ^ "/" ^ leaf

let dir_ref id = if id = root_id then Root else Dir id
let name_max_local = 250
let escape_prefix = ".tsync-esc-"

let storable leaf =
  String.length leaf <= name_max_local
  && (not (String.starts_with ~prefix:".tsync-" leaf))
  && not
       (String.exists
          (fun c -> Char.code c < 0x20 || String.contains "\"*:<>?\\|" c)
          leaf)

let escape leaf =
  if storable leaf then leaf else escape_prefix ^ Xxh.hex16 (Xxh.string leaf)

let escape_path p =
  if p = "" then ""
  else String.concat "/" (List.map escape (String.split_on_char '/' p))

(* An internal leaf begins with the sentinel and is not an escape handle. *)
let is_internal_local leaf =
  String.starts_with ~prefix:".tsync-" leaf
  && not (String.starts_with ~prefix:escape_prefix leaf)

let is_temp_name n =
  String.starts_with ~prefix:".tsync-tmp-" n
  && String.ends_with ~suffix:".tmp" n
  && String.length n >= 15

let temp_owner n =
  if not (is_temp_name n) then None
  else (
    let middle = String.sub n 11 (String.length n - 15) in
    match String.split_on_char '-' middle with
      | [pid; seq]
        when pid <> "" && seq <> ""
             && String.for_all (fun c -> c >= '0' && c <= '9') (pid ^ seq) ->
          int_of_string_opt pid
      | _ -> None)

let temp_seq = Atomic.make 0

let temp_name () =
  Printf.sprintf ".tsync-tmp-%d-%d.tmp" (Unix.getpid ())
    (Atomic.fetch_and_add temp_seq 1)
