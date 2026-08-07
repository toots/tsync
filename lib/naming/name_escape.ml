let sentinel = ".tsync-esc-"
let dir_marker = ".tsync-name"

(* NAME_MAX is 255 bytes on the targeted filesystems; the margin leaves room for
   any suffix appended to a stored leaf. *)
let name_max = 250
let hash c = Xxhash.hash_hex c 0
let is_escaped name = String.starts_with ~prefix:sentinel name

(* Illegal in a filename component on FAT/exFAT/NTFS, plus control characters.
   Escaped even where the local filesystem would accept them. *)
let is_portable_char = function
  | '"' | '*' | ':' | '<' | '>' | '?' | '\\' | '|' -> false
  | c when Char.code c < 32 -> false
  | _ -> true

let representable c =
  String.length c <= name_max
  && (not (String.starts_with ~prefix:sentinel c))
  && String.for_all is_portable_char c

let encode_component c = if representable c then c else sentinel ^ hash c

let encode_key rel =
  String.split_on_char '/' rel |> List.map encode_component |> String.concat "/"
