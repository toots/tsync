type place = { name : string; rel : string }
type t = [ `Domain of place | `Local of string ]
type reading = [ `Either | `In_domain ]
type arg = { token : string; reading : reading }

let typed a = a.token

let strip_leading_slash s =
  if String.length s > 0 && s.[0] = '/' then String.sub s 1 (String.length s - 1)
  else s

(* [<domain>:<path>] names a domain whether or not it is mounted here, which a
   path alone cannot do. Only a name the config knows is read that way, so a
   local file whose name happens to carry a colon still reaches the filesystem. *)
let said_outright cfg token =
  match String.index_opt token ':' with
    | None -> None
    | Some i ->
        let name = String.sub token 0 i in
        let rel = String.sub token (i + 1) (String.length token - i - 1) in
        if List.mem name (Common.domain_names cfg) then
          Some { name; rel = strip_leading_slash rel }
        else None

(* A relative token is answered before the cwd is consulted, so a command that
   only ever means the domain reads [b] as the domain's [b] wherever it is run
   from -- which is what it did before any of this was one function. *)
let resolve ?domain cfg a =
  match said_outright cfg a.token with
    | Some place -> `Domain place
    | None -> (
        match (a.reading, Filename.is_relative a.token) with
          | `In_domain, true ->
              let name, _ =
                Domain.target ?domain ~paths:Common.runtime_paths cfg
              in
              `Domain { name; rel = strip_leading_slash a.token }
          | _ -> (
              match
                Daemons.domain_for_path ?domain ~paths:Common.runtime_paths cfg
                  a.token
              with
                | Some (d, rel) -> `Domain { name = d.Conf_parsing.name; rel }
                | None | (exception _) -> `Local a.token))

let place ?domain cfg a =
  match resolve ?domain cfg a with
    | `Domain p -> Ok p
    | `Local p -> Error (p ^ ": under no domain this machine serves")

(* The mirror holds a sidecar for every published file whether or not its bytes
   are cached, so this is the same source [tsync ls] reads and it costs no round
   trip. *)
let children_of ~name ~rel cfg =
  let (module C : Conf_lwt.S) = Common.make_conf ~domain:name cfg in
  let module Lk = Logical_key.Make (C) in
  let module Mf = Checkout_lwt.Make (C) in
  (* ponytail: one manifest parse per entry, which is what recovers an escaped
     leaf's real name; a folder in the tens of thousands would want the names
     kept beside the tree. *)
  let files, dirs = Lwt_main.run (Mf.list_children ~prefix:(Lk.dir rel) ()) in
  List.map (fun d -> d ^ "/") dirs
  @ List.map
      (fun (l : Checkout.listed) -> Logical_key.leaf l.Checkout.key)
      files

let matching ~prefix xs = List.filter (fun x -> String.starts_with ~prefix x) xs

(* The directory the token is inside, and the part of a name it has typed. *)
let split_at_slash rel =
  match String.rindex_opt rel '/' with
    | None -> ("", rel)
    | Some i ->
        (String.sub rel 0 i, String.sub rel (i + 1) (String.length rel - i - 1))

let in_domain_items ~name ~token ~rel cfg =
  let dir, typed = split_at_slash rel in
  let shown child =
    let full = if dir = "" then child else dir ^ "/" ^ child in
    (* The token is replaced whole, so what is offered carries back whatever
       named the domain. *)
      match String.index_opt token ':' with
      | Some i -> String.sub token 0 i ^ ":/" ^ full
      | None -> full
  in
  List.map
    (fun c -> Cmdliner.Arg.Completion.string (shown c))
    (matching ~prefix:typed (children_of ~name ~rel:dir cfg))

(* A caller with no config, or one naming a domain this machine cannot build,
   gets ordinary paths rather than an error reported on every keystroke. *)
let complete reading ctx ~token =
  let domain = Option.join ctx in
  let paths = Cmdliner.Arg.Completion.[files; dirs] in
  match
    let cfg = Common.load_config () in
    match said_outright cfg token with
      | Some { name; rel } -> in_domain_items ~name ~token ~rel cfg
      | None ->
          let named =
            List.map
              (fun n -> Cmdliner.Arg.Completion.string (n ^ ":/"))
              (matching ~prefix:token (Common.domain_names cfg))
          in
          let here =
            match reading with
              | `Either -> []
              | `In_domain ->
                  let name, _ =
                    Domain.target ?domain ~paths:Common.runtime_paths cfg
                  in
                  in_domain_items ~name ~token ~rel:token cfg
          in
          named @ here @ paths
  with
    | items -> Ok items
    | exception _ -> Ok paths

let conv reading =
  Cmdliner.Arg.Conv.make ~docv:"PATH"
    ~completion:
      (Cmdliner.Arg.Completion.make ~context:Common.domain_arg
         (complete reading))
    ~parser:(fun token -> Ok { token; reading })
    ~pp:(fun ppf a -> Format.pp_print_string ppf a.token)
    ()

(* [tsync start --mount] moves the mount without touching the config, and only
   ever for a lone domain ({!Cmd_start}), so a path under one belongs to that
   domain and the running daemon is the only thing that knows where it put it. *)
let mounted_elsewhere ?domain cfg path =
  let name, socket_path =
    Domain.target ?domain ~paths:Common.runtime_paths cfg
  in
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
let item ?domain a =
  let cfg = Common.load_config () in
  let path = a.token in
  let found =
    match resolve ?domain cfg a with
      | `Domain { name; rel } -> Some (name, rel)
      | `Local p -> mounted_elsewhere ?domain cfg p
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
