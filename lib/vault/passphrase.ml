let min_length = 16

let scalars s =
  let n = ref 0 and i = ref 0 in
  while !i < String.length s do
    let d = String.get_utf_8_uchar s !i in
    incr n;
    i := !i + Uchar.utf_decode_length d
  done;
  !n

let of_typed typed =
  let passphrase = String.trim typed in
  if scalars passphrase < min_length then
    Error (Printf.sprintf "a passphrase has at least %d characters" min_length)
  else Ok passphrase
