(* Client-side name escaping for the local manifest mirror.

   A real path component is stored on the local filesystem verbatim — the
   unadulterated original name — whenever the filesystem can hold it. When it
   cannot (the name exceeds the per-component byte limit, or it collides with
   the escape sentinel), the component is replaced by a fixed-length hashed
   handle [sentinel ^ hash]. A handle is lossy, so the real name is recovered
   elsewhere: for a file from its manifest body's [path] field, for a directory
   from a local-only [dir_marker] file written inside it.

   The sentinel embeds "tsync" and leads with a dot so handles sort together and
   read as internal; any real name that happens to start with it is itself
   escaped, so the prefix unambiguously marks an escaped component. *)

let sentinel = ".tsync-esc-"
let dir_marker = ".tsync-name"

(* NAME_MAX is 255 bytes on the filesystems we target; leave room for the
   ".tmp" suffix the atomic-write path appends to a leaf. *)
let name_max = 250
let hash c = Xxhash.hash_hex c 0
let is_escaped name = String.starts_with ~prefix:sentinel name

(* Characters that are illegal in a filename component on FAT/exFAT/NTFS (plus
   control characters); a name containing one can't be stored verbatim on those
   filesystems, so it is escaped even where the local FS would accept it. *)
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
