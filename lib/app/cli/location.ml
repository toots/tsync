(* [tsync start --mount] moves the mount without touching the config, and only
   ever for a lone domain ({!Cmd_start}), so a path under one belongs to that
   domain and the running daemon is the only thing that knows where it put it. *)
let mounted_elsewhere ?domain cfg path =
  let name, socket_path = Domain.target ?domain ~paths:Common.runtime_paths cfg in
  let field k = function `Assoc o -> List.assoc_opt k o | _ -> None in
  let mount =
    match Ipc.action ~socket_path ~domain:name "stats" with
      | fields -> (
          match field "domains" (`Assoc fields) with
            | Some (`List (d :: _)) -> (
                match field "frontends" d with
                  | Some (`List fs) ->
                      List.find_map
                        (fun f ->
                          match field "mountPoint" f with
                            | Some (`String p) when p <> "" -> Some p
                            | _ -> None)
                        fs
                  | _ -> None)
            | _ -> None)
      | exception _ -> None
  in
  match mount with
    | Some m when String.starts_with ~prefix:(m ^ "/") path ->
        Some
          ( name,
            String.sub path
              (String.length m + 1)
              (String.length path - String.length m - 1) )
    | _ -> None

(* A path a user typed, named the way the daemon knows it. Resolved on this side
   because this side knows where the mirror is: the folder markers say which id
   holds the item, so the request carries a reference and the daemon has one way
   to be told which item it is about.

   The kind is not asked for. Every part of the key this reads — its path, its
   leaf, its parent — is the same whichever it is, and whether a marker exists
   is what says the item is a folder. *)
let item ?domain path =
  let cfg = Common.load_config () in
  let found =
    match Daemons.domain_for_path ?domain ~paths:Common.runtime_paths cfg path with
      | Some (d, rel) -> Some (d.Conf_parsing.name, rel)
      | None -> mounted_elsewhere ?domain cfg path
  in
  match found with
    | None -> Error (path ^ ": under no domain this machine serves")
    | Some (name, rel) -> (
        let (module C : Conf_lwt.S) = Common.make_conf ~domain:name cfg in
        let module Lk = Logical_key.Make (C) in
        let found =
          Oneshot.run
            (Folder_ids_lwt.ref_of_key ~cache_root:C.cache_root
               ~domain_name:C.domain_name (Lk.file rel))
        in
        match found with
          | Some item -> Ok (C.domain_name, item)
          | None -> Error (path ^ ": this client has not resolved its folder"))

