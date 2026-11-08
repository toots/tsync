open Tsync_core

external write : string -> string -> unit = "tsync_cred_write"
external list : string -> (string * string) list = "tsync_cred_list"
external delete_target : string -> unit = "tsync_cred_delete"

let prefix name = "tsync-vault:" ^ Xxh.hex16 (Xxh.string ~seed:0L name) ^ ":"

let entries name =
  let prefix = prefix name in
  List.filter_map
    (fun (target, secret) ->
      if String.starts_with ~prefix target then (
        let n = String.length prefix in
        Some (String.sub target n (String.length target - n), secret, target))
      else None)
    (list (prefix ^ "*"))

let keystore f =
  try f () with Failure reason -> Fail.raise_ Fail.Local "%s" reason

(* §10.6: the new entry is written before the others go, so one always
   stands. *)
let put ~domain ~key_id ~key =
  keystore (fun () ->
      write (prefix domain ^ key_id) key;
      List.iter
        (fun (id, _, target) -> if id <> key_id then delete_target target)
        (entries domain))

let get ~domain =
  keystore (fun () ->
      match entries domain with
        | (key_id, key, _) :: _ -> Some (key_id, key)
        | [] -> None)

let delete ~domain =
  keystore (fun () ->
      List.iter (fun (_, _, target) -> delete_target target) (entries domain))

let register () =
  Tsync_owner.Keystore.register
    { name = "Credential Manager"; put; get; delete }
