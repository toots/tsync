open Lwt.Syntax

let strip_prefix ~prefix s =
  if
    String.length s > String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  then
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  else s

let version_dir ~s3_key ~domain_prefix ~versions_prefix =
  versions_prefix ^ strip_prefix ~prefix:domain_prefix s3_key ^ "/"

let version_key ~s3_key ~domain_prefix ~versions_prefix =
  let ts = Int64.of_float (Unix.gettimeofday () *. 1e9) in
  Printf.sprintf "%s%Ld"
    (version_dir ~s3_key ~domain_prefix ~versions_prefix)
    ts

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

let save ~backends ~domain_prefix ~versions_prefix ~key =
  match backends with
    | [] -> Lwt.return_unit
    | (module B : Backend.S) :: _ -> (
        let* head = B.head_opt ~key () in
        match head with
          | None -> Lwt.return_unit
          | Some _ ->
              let dst_key =
                version_key ~s3_key:key ~domain_prefix ~versions_prefix
              in
              Lwt_list.iter_s
                (fun (module B : Backend.S) -> B.copy ~src_key:key ~dst_key ())
                backends)
