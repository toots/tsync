(* Each line is five dice digits, a tab and the word; the four hyphenated words
   are left out, as passphrases join words with [-]. *)
let words =
  lazy
    (Array.of_list
       (List.filter_map
          (fun line ->
            match String.index_opt line '\t' with
              | Some i ->
                  let w =
                    String.sub line (i + 1) (String.length line - i - 1)
                  in
                  if String.contains w '-' then None else Some w
              | None -> None)
          (String.split_on_char '\n' Eff_large_wordlist.text)))

let count = 7772

(* Rejection sampling over 16 bits: below the largest multiple of [count], every
   word is equally likely. Each draw reads one batch of the CSPRNG. *)
let passphrase n =
  let words = Lazy.force words in
  assert (Array.length words = count);
  let limit = 65536 / count * count in
  let rec draw acc drawn pool i =
    if drawn = n then acc
    else if i + 2 > String.length pool then
      draw acc drawn (Tsync_core.Ids.urandom ((2 * (n - drawn)) + 16)) 0
    else (
      let v = (Char.code pool.[i] lsl 8) lor Char.code pool.[i + 1] in
      if v >= limit then draw acc drawn pool (i + 2)
      else draw (words.(v mod count) :: acc) (drawn + 1) pool (i + 2))
  in
  String.concat "-" (draw [] 0 "" 0)
