(* Split a version key [<versions_prefix><rel>/<ts>] into its identity [rel] (a
   folder-id/leaf-hash pair under the inode layout) and its timestamp. [rel] is
   used only as an opaque grouping key; the timestamp orders versions. *)
let parse ~versions_prefix key =
  let n = String.length versions_prefix in
  if String.length key <= n || String.sub key 0 n <> versions_prefix then None
  else (
    let rest = String.sub key n (String.length key - n) in
    match String.rindex_opt rest '/' with
      | Some i when i < String.length rest - 1 ->
          Some
            ( String.sub rest 0 i,
              String.sub rest (i + 1) (String.length rest - i - 1) )
      | _ -> None)
