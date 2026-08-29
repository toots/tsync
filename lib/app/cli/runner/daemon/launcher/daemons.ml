(* The [frontend] override if given (it must be one the domain lists), else the
   domain's first. Resolved at call time, not module-init, so frontend
   registration — a link-order side effect — has already happened. *)
let frontend_names (d : Conf_parsing.domain) =
  List.map
    (fun (f : Conf_parsing.frontend_config) -> f.Conf_parsing.frontend_type)
    d.Conf_parsing.frontends

let frontend_for ?frontend (d : Conf_parsing.domain) : (module Frontend.S) =
  let names = frontend_names d in
  let name =
    match frontend with
      | Some name ->
          if List.mem name names then name
          else
            failwith
              (Printf.sprintf
                 "frontend %s not configured for domain %s (configured: %s)"
                 name d.Conf_parsing.name (String.concat ", " names))
      | None -> (
          match names with
            | n :: _ -> n
            | [] ->
                failwith ("domain " ^ d.Conf_parsing.name ^ " has no frontends")
          )
  in
  match Frontend.find name with
    | Some m -> m
    | None ->
        failwith
          (Printf.sprintf
             "frontend %s is configured but not compiled into this binary" name)

(* A path names its own domain by sitting under one of that domain's roots.
   [domain] restricts the search to one, for a caller that was told which. *)
let domain_for_path ?domain ~paths cfg path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let rel root =
    let root = if root = "/" then "" else root in
    if path = root then Some ""
    else if String.starts_with ~prefix:(root ^ "/") path then
      Some
        (String.sub path
           (String.length root + 1)
           (String.length path - String.length root - 1))
    else None
  in
  let under d =
    List.find_map rel (Conf_parsing.roots_of ~data_dir:paths.Runtime.data_dir d)
  in
  cfg.Conf_parsing.domains
  |> List.filter (fun (d : Conf_parsing.domain) ->
      match domain with Some n -> d.Conf_parsing.name = n | None -> true)
  |> List.find_map (fun d -> Option.map (fun r -> (d, r)) (under d))

(* A path under no domain's root falls back to the default domain, so the answer
   is a daemon saying it does not know the file rather than a connection to
   nothing. *)
let socket_for_path ~paths cfg path =
  match domain_for_path ~paths cfg path with
    | Some (d, _) -> Runtime.domain_socket_path paths d.Conf_parsing.name
    | None | (exception _) -> Domain.socket ~paths cfg

(* For a command that reports rather than acts: every configured domain, never
   one. The default domain, and [--domain] with it, say which domain a command
   acts on; a report answers for the machine, and narrowing it would leave the
   rest of what runs here unaccounted for.

   Each domain keeps its own name even where the socket is shared, since that is
   what the macOS daemon routes on. *)
let all ~paths cfg =
  match cfg.Conf_parsing.domains with
    | [] -> failwith "no domains configured"
    | domains ->
        (* Asked of each configured frontend rather than assumed: a domain served
           only by a listener has no socket of its own, and knocking on one
           nothing binds reports a daemon down that was never up. Frontends
           sharing a path answer the same one and collapse. *)
        List.concat_map
          (fun (d : Conf_parsing.domain) ->
            List.filter_map
              (fun (f : Conf_parsing.frontend_config) ->
                match Frontend.find f.Conf_parsing.frontend_type with
                  | None -> None
                  | Some (module F : Frontend.S) -> (
                      match
                        match F.serving with
                          | Frontend.Daemon d -> d.Frontend.listens
                          | Frontend.Commands _ -> None
                      with
                        | None -> None
                        | Some `Domain_socket ->
                            Some
                              ( d.Conf_parsing.name,
                                Runtime.domain_socket_path paths
                                  d.Conf_parsing.name )
                        (* Named for the domain, not the listener: one process
                           fronts several and routes on the name, so a report
                           has to ask it once per domain to hear about each. *)
                        | Some `Proxy_socket ->
                            Some
                              ( d.Conf_parsing.name,
                                Runtime.proxy_socket_path paths )))
              d.Conf_parsing.frontends)
          domains
        (* The process converging every domain, which presents none of them and
           so is named for the work rather than for a domain or a frontend. *)
        @ [("sync", Runtime.sync_socket_path paths)]
        |> List.sort_uniq compare
