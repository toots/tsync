open Tsync_core

let denied path why = Fail.raise_ Fail.Denied "%s: %s" path why

let components path =
  List.filter (fun c -> c <> "") (String.split_on_char '/' path)

(* The parent is walked from the root with lstat, so no link on the way
   redirects it. A host declaring no roots (security-model §7.3) walks it from
   [/]. *)
let check_under ~roots path =
  let roots = if roots = [] then ["/"] else roots in
  if Filename.is_relative path then denied path "not an absolute path";
  let parts = components path in
  if List.exists (fun c -> c = "." || c = "..") parts then
    denied path "not a normalised path";
  let under root =
    let r = components root in
    let rec strip r p =
      match (r, p) with
        | [], rest -> Some rest
        | a :: r, b :: p when a = b -> strip r p
        | _ -> None
    in
    match strip r parts with
      | Some (_ :: _ as rest) -> Some (root, rest)
      | _ -> None
  in
  match List.find_map under roots with
    | None -> denied path "outside the roots this host declares"
    | Some (root, rest) ->
        let rec walk dir = function
          | [] | [_] -> ()
          | c :: rest -> (
              let d = Filename.concat dir c in
              match Unix.lstat d with
                | { st_kind = S_DIR; _ } -> walk d rest
                | _ -> denied path "a component is not a directory"
                | exception Unix.Unix_error _ ->
                    denied path "a parent directory is missing")
        in
        walk root rest

let check_dest ~roots path =
  check_under ~roots path;
  match Unix.lstat path with
    | _ -> denied path "already exists"
    | exception Unix.Unix_error (ENOENT, _, _) -> ()
    | exception Unix.Unix_error _ -> denied path "cannot be checked"

let check_staging ~roots path =
  check_under ~roots path;
  match Unix.lstat path with
    | { st_kind = S_REG; st_uid; _ } when st_uid = Unix.getuid () -> ()
    | _ -> denied path "not a regular file owned by this user"
    | exception Unix.Unix_error _ -> denied path "missing"
