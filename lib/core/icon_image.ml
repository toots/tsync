let converter = Atomic.make None

let helper ~max_side ~max_bytes ~deadline source =
  match
    Media_helper.run ~max_output:max_bytes ~deadline
      ["icon"; string_of_int max_side; string_of_int max_bytes; source]
  with
    | Some icon -> icon
    | None -> Fail.invalid "the image could not be converted"

let current () =
  match Atomic.get converter with
    | Some convert -> Some convert
    | None when Media_helper.available () -> Some helper
    | None -> None

let available () = Option.is_some (current ())
