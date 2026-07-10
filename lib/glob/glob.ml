(* Simple shell-style glob matcher.
   Spec:
   - [*]  matches any sequence of characters except [/]
   - [**] matches any sequence of characters including [/]
   - [?]  matches any single character except [/]
   - everything else matches itself literally (including [+], [.], [(], [)], …)
   No brace expansion, no character classes — we don't need them. *)

type t = string

let of_pattern p = p

let rec match_from pat pi str si =
  if pi = String.length pat then si = String.length str
  else (
    match pat.[pi] with
      | '*' when pi + 1 < String.length pat && pat.[pi + 1] = '*' ->
          (* **/ matches zero or more path segments (including their trailing /),
         so **/.git matches both .git and a/b/.git.
         Plain ** (not followed by /) matches any sequence of characters. *)
          let rest =
            if pi + 2 < String.length pat && pat.[pi + 2] = '/' then pi + 3
            else pi + 2
          in
          let rec try_from i =
            if match_from pat rest str i then true
            else if i < String.length str then try_from (i + 1)
            else false
          in
          try_from si
      | '*' ->
          (* * matches any sequence that does not cross a path separator *)
          let rec try_from i =
            if match_from pat (pi + 1) str i then true
            else if i < String.length str && str.[i] <> '/' then try_from (i + 1)
            else false
          in
          try_from si
      | '?' ->
          si < String.length str
          && str.[si] <> '/'
          && match_from pat (pi + 1) str (si + 1)
      | c ->
          si < String.length str
          && str.[si] = c
          && match_from pat (pi + 1) str (si + 1))

let matches pat str = match_from pat 0 str 0
