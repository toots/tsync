type kind = String | Bool | Int | Size | Path | List | Float

type field = {
  name : string;
  label : string;
  kind : kind;
  default : string option;
  secret : bool;
  required : bool;
  check : string -> string option;
}

let f ?(secret = false) ?(required = false) ?default ?(check = fun _ -> None)
    name label kind =
  { name; label; kind; default; secret; required; check }

type value =
  | S of string
  | B of bool
  | I of int
  | F of float
  | L of string list

let is_loopback host =
  host = "localhost" || host = "::1" || host = "[::1]"
  || String.starts_with ~prefix:"127." host

let host_of_url url =
  let rest =
    match String.index_opt url ':' with
      | Some i when i + 3 <= String.length url ->
          String.sub url (i + 3) (String.length url - i - 3)
      | _ -> url
  in
  let hostport =
    match String.index_opt rest '/' with
      | Some i -> String.sub rest 0 i
      | None -> rest
  in
  if String.starts_with ~prefix:"[" hostport then (
    match String.index_opt hostport ']' with
      | Some i -> String.sub hostport 0 (i + 1)
      | None -> hostport)
  else (
    match String.rindex_opt hostport ':' with
      | Some i -> String.sub hostport 0 i
      | None -> hostport)

(* security §9: plaintext only to a loopback host. *)
let http_url ?(bare_host = false) url =
  if String.starts_with ~prefix:"http://" url then
    if is_loopback (host_of_url url) then None
    else Some "plain http is refused for a host that is not a loopback address"
  else if String.starts_with ~prefix:"https://" url || bare_host then None
  else Some "expected an http(s) URL"

let min_secret_length = 32

let secret_length s =
  if String.length s < min_secret_length then
    Some (Printf.sprintf "must have at least %d characters" min_secret_length)
  else None

let absolute_path p =
  if String.starts_with ~prefix:"/" p then None
  else Some "must be an absolute path"

let absolute_or_home p =
  if String.starts_with ~prefix:"/" p || String.starts_with ~prefix:"~/" p then
    None
  else Some "must be absolute or start with ~/"
