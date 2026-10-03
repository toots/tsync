open Tsync_core

(* Every directory between the root and the key is refused if it is a
   symbolic link, so a link planted in the store cannot redirect an access. *)
let check_no_links root key =
  let parts = String.split_on_char '/' key in
  let rec go dir = function
    | [] | [_] -> ()
    | seg :: rest -> (
        let d = Filename.concat dir seg in
        match Fs.lstat_opt d with
          | Some { st_kind = S_LNK; _ } ->
              Fail.invalid "%s: a symbolic link inside the store" d
          | Some { st_kind = S_DIR; _ } -> go d rest
          | Some _ -> Fail.raise_ Fail.Refused "%s: not a directory" d
          | None -> ())
  in
  go root parts

let path root key =
  let key = Key.to_string key in
  check_no_links root key;
  Filename.concat root key
