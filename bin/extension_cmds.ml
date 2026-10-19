(* The CLI's view of extension domains (spec extensions README §6.1): which
   domains use an extension, where a new record goes, and every domain asked. *)
open Cmdliner
open Tsync_core
open Tsync_config
open Cli

let dname (d : Config.domain) = Domain_name.to_string d.name

(* A domain with no extensions configured follows its main (05 §2.1 rule 5):
   only its owner knows whether it uses an extension. *)
let follows (d : Config.domain) = d.extensions = None

let using ~extension config =
  List.filter
    (fun (d : Config.domain) ->
      match d.extensions with Some l -> List.mem extension l | None -> true)
    config.Config.domains

(* README §6.1: a new record goes to --domain, else the only domain using the
   extension, else the default domain when it uses it. *)
let write_domain ?name ~extension config =
  match (name, using ~extension config) with
    | Some n, _ -> domain ~name:n config
    | None, [d] -> d
    | None, candidates -> (
        match Paths.default_domain () with
          | Some n when List.exists (fun d -> dname d = n) candidates ->
              domain ~name:n config
          | _ ->
              Fail.invalid "pick one with --domain: %s"
                (match candidates with
                  | [] -> "no domain uses " ^ extension
                  | l -> String.concat ", " (List.map dname l)))

(* README §6.1: every domain answers on its own; refused only when none did. *)
let each ?name ~extension config f =
  let domains =
    match name with
      | Some n -> [domain ~name:n config]
      | None -> using ~extension config
  in
  if domains = [] then Fail.invalid "no domain uses %s" extension;
  let answers =
    List.filter
      (function
        | d, Error (e : Fail.t) ->
            not (follows d && e.kind = Invalid && name = None)
        | _ -> true)
      (List.map (fun d -> (d, try Ok (f d) with Fail.E e -> Error e)) domains)
  in
  if answers = [] then Fail.invalid "no domain uses %s" extension;
  if List.for_all (fun (_, a) -> Result.is_error a) answers then (
    match answers with
      | (_, Error e) :: _ -> raise (Fail.E e)
      | _ -> assert false)
  else (
    List.iter
      (function
        | d, Error (e : Fail.t) ->
            prerr_endline ("tsync: " ^ dname d ^ ": " ^ e.reason)
        | _ -> ())
      answers;
    List.filter_map
      (function d, Ok v -> Some (d, v) | _, Error _ -> None)
      answers)

let verb name ~doc term =
  cmd name ~doc
    Term.(
      const (fun f domain verbose ->
          set_verbose verbose;
          run (fun () -> f ?name:domain (config ())))
      $ term $ domain_arg $ verbose)
