type t =
  [ `Root
  | `Dir of string
  | `File of string * string  (** parent folder id, leaf name *)
  | `Logical_key of Logical_key.t
  | `Bad of string ]

let dir_prefix = "d:"
let file_prefix = "f:"
let root_form = "root"

let has_prefix p s =
  String.length s > String.length p && String.starts_with ~prefix:p s

let drop_prefix p s =
  String.sub s (String.length p) (String.length s - String.length p)

let to_string = function
  | `Root -> root_form
  | `Dir id -> dir_prefix ^ id
  | `File (id, name) -> file_prefix ^ id ^ "/" ^ name
  | `Logical_key k -> Logical_key.to_string k
  | `Bad s -> s

(* Total: an unparseable reference is a value, so the caller answers with an
   error rather than the request failing. *)
module Make (D : Logical_key.Domain) = struct
  module K = Logical_key.Make (D)

  let parse s =
    if s = root_form then `Root
    else if has_prefix dir_prefix s then (
      let id = drop_prefix dir_prefix s in
      if id = Stored_key.root_id then `Root else `Dir id)
    else if has_prefix file_prefix s then (
      let rest = drop_prefix file_prefix s in
      (* Neither a leaf name nor a folder id can contain "/", so the first one
         separates them. *)
        match String.index_opt rest '/' with
        | None -> `Bad s
        | Some i ->
            let id = String.sub rest 0 i in
            let name = String.sub rest (i + 1) (String.length rest - i - 1) in
            if id = "" || name = "" then `Bad s else `File (id, name))
    else (match K.of_string s with Some k -> `Logical_key k | None -> `Bad s)
end
