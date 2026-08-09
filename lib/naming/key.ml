(* Shape of a logical key, in one place: [domain_prefix ^ real-path], with a
   directory key ending in "/". Nothing below is more than a few lines; the
   point is that each has exactly one spelling. *)

let strip_prefix ~domain_prefix key =
  if String.starts_with ~prefix:domain_prefix key then (
    let n = String.length domain_prefix in
    String.sub key n (String.length key - n))
  else key

let is_dir key = String.ends_with ~suffix:"/" key

let chop_slash key =
  if is_dir key then String.sub key 0 (String.length key - 1) else key

let leaf ~domain_prefix key =
  Filename.basename (chop_slash (strip_prefix ~domain_prefix key))

let ensure_slash key = if is_dir key then key else key ^ "/"

(* Parent of a relative path, with the root spelled [""] rather than
   {!Filename.dirname}'s ["."] — [""] is what joins and resolves correctly. *)
let parent rel = match Filename.dirname rel with "." -> "" | d -> d
let join rel name = if rel = "" then name else rel ^ "/" ^ name
