let alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
let size = 16
let spelled_length = 26
let generate () = Tsync_core.Ids.urandom size

(* 128 bits read 5 at a time, most significant first; the last symbol takes the
   final 3 bits and two zero padding bits. *)
let to_string bytes =
  let bit i = (Char.code bytes.[i / 8] lsr (7 - (i mod 8))) land 1 in
  let symbol k =
    let v = ref 0 in
    for i = 5 * k to (5 * k) + 4 do
      v := (!v lsl 1) lor if i < 8 * size then bit i else 0
    done;
    alphabet.[!v]
  in
  let s = String.init spelled_length symbol in
  String.concat "-"
    [
      String.sub s 0 5;
      String.sub s 5 5;
      String.sub s 10 5;
      String.sub s 15 5;
      String.sub s 20 6;
    ]

let normalise input =
  let b = Buffer.create spelled_length in
  String.iter
    (fun c ->
      match Char.lowercase_ascii c with
        | ' ' | '-' -> ()
        | 'i' | 'l' -> Buffer.add_char b '1'
        | 'o' -> Buffer.add_char b '0'
        | c -> Buffer.add_char b c)
    input;
  Buffer.contents b

let of_string input =
  let s = normalise input in
  let values =
    List.map (String.index_opt alphabet) (List.of_seq (String.to_seq s))
  in
  if String.length s <> spelled_length || List.mem None values then None
  else (
    let values = List.map Option.get values in
    let bits =
      List.concat_map
        (fun v -> List.init 5 (fun i -> (v lsr (4 - i)) land 1))
        values
    in
    let padding = List.filteri (fun i _ -> i >= 8 * size) bits in
    if List.exists (( <> ) 0) padding then None
    else (
      let bits = Array.of_list bits in
      Some
        (String.init size (fun byte ->
             let v = ref 0 in
             for i = 0 to 7 do
               v := (!v lsl 1) lor bits.((8 * byte) + i)
             done;
             Char.chr !v))))

let id key =
  Tsync_core.Ids.hex
    (String.sub
       Digestif.SHA256.(
         to_raw_string (digest_string ("tsync-vault-secret-key/" ^ key)))
       0 8)
