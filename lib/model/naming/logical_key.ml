(* The prefix travels in the value rather than being reapplied at each use, so
   [to_string] needs no domain and two keys built from different domains cannot
   be mistaken for each other.

   [path] holds no trailing separator whatever the kind: that separator is the
   wire spelling of [Dir] and is written in exactly one place below. *)
type kind = File | Dir
type t = { prefix : string; path : string; kind : kind }

let to_string t =
  match t.kind with
    | File -> t.prefix ^ t.path
    | Dir -> if t.path = "" then t.prefix else t.prefix ^ t.path ^ "/"

let path t = t.path
let leaf t = if t.path = "" then "" else Filename.basename t.path
let kind t = match t.kind with File -> `File | Dir -> `Dir
let is_root t = t.path = "" && t.kind = Dir

let parent t =
  let path = match Filename.dirname t.path with "." | "/" -> "" | d -> d in
  { t with path; kind = Dir }

let join path name = if path = "" then name else path ^ "/" ^ name

let inside t name kind =
  match t.kind with
    | File ->
        invalid_arg
          (Printf.sprintf "Logical_key: %S names a file, not a folder" t.path)
    | Dir -> { t with path = join t.path name; kind }

let file_in t name = inside t name File
let dir_in t name = inside t name Dir

let as_prefix t =
  match t.kind with
    | Dir -> to_string t
    | File ->
        invalid_arg
          (Printf.sprintf "Logical_key: %S names a file, not a folder" t.path)

let equal a b = a.prefix = b.prefix && a.path = b.path && a.kind = b.kind

let compare a b =
  match String.compare a.prefix b.prefix with
    | 0 -> (
        match String.compare a.path b.path with
          | 0 -> Stdlib.compare a.kind b.kind
          | n -> n)
    | n -> n

module type Domain = sig
  val domain_prefix : string
end

module Make (D : Domain) = struct
  (* A separator on either end is punctuation rather than part of the name: a
     frontend hands over what its own path space gave it. *)
  let trim rel =
    let rel =
      if String.length rel > 0 && rel.[0] = '/' then
        String.sub rel 1 (String.length rel - 1)
      else rel
    in
    if String.length rel > 0 && rel.[String.length rel - 1] = '/' then
      String.sub rel 0 (String.length rel - 1)
    else rel

  let file rel = { prefix = D.domain_prefix; path = trim rel; kind = File }
  let dir rel = { prefix = D.domain_prefix; path = trim rel; kind = Dir }
  let root = { prefix = D.domain_prefix; path = ""; kind = Dir }

  let of_rel rel =
    if rel = "" then root
    else if String.ends_with ~suffix:"/" rel then dir rel
    else file rel

  let of_string s =
    if not (String.starts_with ~prefix:D.domain_prefix s) then None
    else (
      let n = String.length D.domain_prefix in
      let rest = String.sub s n (String.length s - n) in
      if rest = "" then Some root
      else if String.ends_with ~suffix:"/" rest then Some (dir rest)
      else Some (file rest))
end
