(* Shape of a logical key, in one place.

   A logical key is [domain_prefix ^ real-path]; a directory key ends in "/".
   Every layer used to spell these transformations out itself, and they had
   drifted — one prefix stripper checked the prefix and another only its length,
   so a key that *was* the bare prefix came back whole from one and empty from
   the other. Nothing below is more than a few lines; the point is that there is
   exactly one of each. *)

let strip_prefix ~domain_prefix key =
  if String.starts_with ~prefix:domain_prefix key then (
    let n = String.length domain_prefix in
    String.sub key n (String.length key - n))
  else key

let is_dir key = String.ends_with ~suffix:"/" key

let chop_slash key =
  if is_dir key then String.sub key 0 (String.length key - 1) else key

let ensure_slash key = if is_dir key then key else key ^ "/"

(* Parent of a relative path, with the root spelled [""] rather than
   {!Filename.dirname}'s ["."] — [""] is what joins and resolves correctly. *)
let parent rel = match Filename.dirname rel with "." -> "" | d -> d
let join rel name = if rel = "" then name else rel ^ "/" ^ name
