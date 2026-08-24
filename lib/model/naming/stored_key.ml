let root_id = ".tsync-root"
let trash_id = ".tsync-trash"
let new_id = Id.short

(* The dual-seed xxHash of the leaf name, matching the chunk-key convention:
   fixed length and filesystem-safe regardless of the real name. *)
let hash_name name = Xxhash.hash_hex name 0 ^ "-" ^ Xxhash.hash_hex name 1
let child_key ~folder_id name = folder_id ^ "/" ^ hash_name name
let index_leaf = ".tsync-index"
let index_key ~folder_id = folder_id ^ "/" ^ index_leaf
let is_index_key key = Filename.basename key = index_leaf
let is_temp_key key = Filename.is_temp_name (Filename.basename key)
let is_dir_key key = String.ends_with ~suffix:"/" key

let folder_id_of ns =
  Filename.basename
    (if is_dir_key ns then String.sub ns 0 (String.length ns - 1) else ns)

let strip_domain ~domain_prefix key =
  if String.starts_with ~prefix:domain_prefix key then
    String.sub key
      (String.length domain_prefix)
      (String.length key - String.length domain_prefix)
  else key

let is_internal key = is_temp_key key || is_index_key key
let is_child_object key = (not (is_dir_key key)) && not (is_internal key)
