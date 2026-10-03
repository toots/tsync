type t = string

let root = Names.root_id
let trash = Names.trash_id
let of_string s = if Names.valid_folder_id s then Some s else None

let v s =
  match of_string s with
    | Some id -> id
    | None -> Fail.invalid "invalid folder id %S" s

let to_string id = id
let mint ~uuid ~counter = Printf.sprintf "%s-%x" (String.sub uuid 0 12) counter
let is_root id = id = root
let equal = String.equal
let compare = String.compare
