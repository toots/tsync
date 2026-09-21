(* Trimmed on the way in, in the one place it happens: a store comparing a body
   against a token that reached it over a wire must not conclude "changed" from
   whitespace. *)
type t = string

let of_body body = String.trim (Bigstring.to_string body)
let to_wire token = token
let of_wire s = String.trim s
let equal = String.equal
