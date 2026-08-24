(* Every name a store keeps for itself carries this, and no name a user gave
   reaches a store carrying it: what would is escaped on the way in. One prefix,
   so a store never has to enumerate its own reserved leaves. *)
let sentinel = ".tsync-"
let reserved leaf = String.starts_with ~prefix:sentinel leaf
let root_id = sentinel ^ "root"
let trash_id = sentinel ^ "trash"
let new_id = Id.short

(* The dual-seed xxHash of the leaf name, matching the chunk-key convention:
   fixed length and filesystem-safe regardless of the real name. *)
let hash_name name = Xxhash.hash_hex name 0 ^ "-" ^ Xxhash.hash_hex name 1
let index_leaf = sentinel ^ "index"

type t = string

let to_string key = key
let in_space ~prefix path = prefix ^ path
let listed key = key
let namespace ~prefix ~folder_id = in_space ~prefix (folder_id ^ "/")
let under key name = key ^ name
let trash_namespace ~prefix = namespace ~prefix ~folder_id:trash_id
let share_key ~prefix token = in_space ~prefix token

let child_key ~prefix ~folder_id name =
  in_space ~prefix (folder_id ^ "/" ^ hash_name name)

let index_key ~prefix ~folder_id =
  in_space ~prefix (folder_id ^ "/" ^ index_leaf)

let is_index_key key = Filename.basename key = index_leaf
let is_temp_key key = Filename.is_temp_name (Filename.basename key)
let is_dir_key key = String.ends_with ~suffix:"/" key

(* A mirror files an item under its real path, so each component is stored as
   itself where it can be and hashed where it cannot: too long for the
   filesystem, carrying a character some of them refuse, or reading as one of
   this store's own names. *)
let escape_leaf = sentinel ^ "esc-"
let is_escaped leaf = String.starts_with ~prefix:escape_leaf leaf

(* NAME_MAX is 255 bytes on the targeted filesystems; the margin leaves room for
   any suffix appended to a stored leaf. *)
let name_max = 250

(* Illegal in a filename component on FAT/exFAT/NTFS, plus control characters.
   Escaped even where the local filesystem would accept them. *)
let portable_char = function
  | '"' | '*' | ':' | '<' | '>' | '?' | '\\' | '|' -> false
  | c when Char.code c < 32 -> false
  | _ -> true

let storable leaf =
  String.length leaf <= name_max
  && (not (reserved leaf))
  && String.for_all portable_char leaf

let escape leaf =
  if storable leaf then leaf else escape_leaf ^ Xxhash.hash_hex leaf 0

let escape_path rel =
  String.split_on_char '/' rel |> List.map escape |> String.concat "/"

(* The two names a mirror keeps beside its manifests: what an escaped directory
   is really called, and which folder id it has. *)
let dir_name_leaf = sentinel ^ "name"
let folder_marker_leaf = sentinel ^ "dir"

let folder_id_of ns =
  Filename.basename
    (if is_dir_key ns then String.sub ns 0 (String.length ns - 1) else ns)

let path_in ~prefix key =
  if String.starts_with ~prefix key then
    String.sub key (String.length prefix)
      (String.length key - String.length prefix)
  else key

(* Reserved wherever it is read, a temp name being one of these too. A handle
   carries the sentinel and is not one of these: it is a name someone chose,
   spelled so a filesystem will hold it. *)
let is_internal key =
  let leaf = Filename.basename key in
  reserved leaf && not (is_escaped leaf)

let is_child_object key = (not (is_dir_key key)) && not (is_internal key)
