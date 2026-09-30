type t = string

let of_string ?local_store s =
  match Names.domain_name_error ?local_store s with None -> Ok s | Some e -> Error e

let v ?local_store s = match of_string ?local_store s with Ok d -> d | Error e -> Fail.invalid "domain %S: %s" s e
let to_string d = d
let equal = String.equal
let compare = String.compare
