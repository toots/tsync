(* Client-side name escaping for the local manifest mirror.

   A path component is stored verbatim whenever the filesystem can hold it. When
   it cannot — over the per-component byte limit, or colliding with the escape
   sentinel — it is replaced by a fixed-length handle [sentinel ^ hash]. A handle
   is lossy, so the real name is recovered elsewhere: for a file from its manifest
   body's [path], for a directory from a local-only [dir_marker] inside it.

   The sentinel leads with a dot so handles sort together and read as internal.
   Any real name starting with it is itself escaped, so the prefix unambiguously
   marks an escaped component. *)

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
