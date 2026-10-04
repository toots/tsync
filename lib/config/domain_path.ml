open Tsync_core

type t =
  | In_domain of { domain : string option; rel : string }
  | Local of string

let rel path =
  String.concat "/" (List.filter (( <> ) "") (String.split_on_char '/' path))

let after prefix token =
  String.sub token (String.length prefix)
    (String.length token - String.length prefix)

(* The longest configured name wins: a domain name may hold a colon. *)
let prefixed (config : Config.t) token =
  if String.starts_with ~prefix:":" token then
    Some (In_domain { domain = None; rel = rel (after ":" token) })
  else
    List.map
      (fun (d : Config.domain) -> Domain_name.to_string d.name)
      config.domains
    |> List.filter (fun name -> String.starts_with ~prefix:(name ^ ":") token)
    |> List.sort (fun a b -> compare (String.length b) (String.length a))
    |> function
    | name :: _ ->
        Some
          (In_domain
             { domain = Some name; rel = rel (after (name ^ ":") token) })
    | [] -> None

let parse config token =
  match prefixed config token with
    | Some t -> t
    | None ->
        Local
          (if Filename.is_relative token then
             Filename.concat (Sys.getcwd ()) token
           else token)

let in_domain config token =
  match prefixed config token with
    | Some (In_domain { domain; rel }) -> Ok (domain, rel)
    | Some (Local _) | None ->
        if Filename.is_relative token then Ok (None, rel token)
        else (
          match Mounts.holding config token with
            | Some (d, rest) ->
                Ok (Some (Domain_name.to_string d.name), rel rest)
            | None -> Error (token ^ " is under no domain's mount point"))

let agree ?name domains =
  match
    List.sort_uniq compare (Option.to_list name @ List.filter_map Fun.id domains)
  with
    | [] -> Ok None
    | [d] -> Ok (Some d)
    | _ :: _ :: _ when name <> None ->
        Error "the domain named in a path differs from --domain"
    | _ -> Error "the paths name more than one domain"
