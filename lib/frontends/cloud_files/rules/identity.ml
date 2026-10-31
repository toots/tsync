type t = { ref_ : string; content_id : string }

let of_item ~ref_ ~is_dir ~content_id =
  {
    ref_;
    content_id = (if is_dir then "" else Option.value ~default:"" content_id);
  }

let encode t = String.concat "\n" ["t1"; t.ref_; t.content_id]

let decode s =
  match String.split_on_char '\n' s with
    | ["t1"; ref_; content_id] when ref_ <> "" -> Some { ref_; content_id }
    | _ -> None
