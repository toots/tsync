(* Parent of a relative path, with the root spelled [""] rather than
   {!Filename.dirname}'s ["."] — [""] is what joins and resolves correctly. *)
let parent rel = match Filename.dirname rel with "." -> "" | d -> d
