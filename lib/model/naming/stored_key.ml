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

let is_child_object key =
  (not (String.ends_with ~suffix:"/" key))
  && (not (Fs_util.is_temp_key key))
  && not (is_index_key key)
