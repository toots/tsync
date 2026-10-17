open Cmdliner
open Tsync_core
open Tsync_config
open Cli
module P = Tsync_owner.Protocol

let dname (d : Config.domain) = Domain_name.to_string d.name

let using config =
  List.filter
    (fun (d : Config.domain) -> List.mem "totp" d.extensions)
    config.Config.domains

(* README §6.1: a new record goes to --domain, else the only domain using the
   extension, else the default domain when it uses it. *)
let write_domain ?name config =
  match (name, using config) with
    | Some n, _ -> domain ~name:n config
    | None, [d] -> d
    | None, candidates -> (
        match Paths.default_domain () with
          | Some n when List.exists (fun d -> dname d = n) candidates ->
              domain ~name:n config
          | _ ->
              Fail.invalid "pick one with --domain: %s"
                (match candidates with
                  | [] -> "no domain uses totp"
                  | l -> String.concat ", " (List.map dname l)))

(* README §6.1: every domain answers on its own; refused only when none did. *)
let each ?name config f =
  let domains =
    match name with Some n -> [domain ~name:n config] | None -> using config
  in
  if domains = [] then Fail.invalid "no domain uses totp";
  let answers =
    List.map (fun d -> (d, try Ok (f d) with Fail.E e -> Error e)) domains
  in
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

(* README §6.1: an id names the record of the one domain that holds it. *)
let holder ?name config id =
  match name with
    | Some n -> domain ~name:n config
    | None -> (
        match
          List.filter
            (fun (_, (l : P.totp_listing)) ->
              List.exists (fun (r : P.totp_row) -> r.id = id) l.rows
              || List.mem id l.corrupt)
            (each config (fun d -> Vault_cmds.ask d (P.Totp_list None)))
        with
          | [(d, _)] -> d
          | [] -> Fail.absent "no record %s" id
          | l ->
              Fail.invalid "%s is in %s: pick one with --domain" id
                (String.concat ", " (List.map (fun (d, _) -> dname d) l)))

(* For reading off a screen: [123 456], [1234 5678]. *)
let grouped code =
  let half = String.length code / 2 in
  String.sub code 0 half ^ " " ^ String.sub code half (String.length code - half)

let verb name ~doc term =
  cmd name ~doc
    Term.(
      const (fun f domain verbose ->
          set_verbose verbose;
          run (fun () -> f ?name:domain (config ())))
      $ term $ domain_arg $ verbose)

let id_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"ID" ~doc:"The record's id.")

let add_cmd =
  let uri =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"URI"
          ~doc:"An otpauth://totp/ URI, as a QR code holds it.")
  in
  verb "add" ~doc:"Add a one-time-password seed from its otpauth URI."
    Term.(
      const (fun uri ?name config ->
          let d = write_domain ?name config in
          say "%s %s" (dname d) (Vault_cmds.ask d (P.Totp_add uri));
          0)
      $ uri)

let list_cmd =
  let filter =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"FILTER"
          ~doc:"Only records whose issuer or account contain it.")
  in
  verb "list" ~doc:"The current codes, with the seconds each has left."
    Term.(
      const (fun filter ?name config ->
          List.iter
            (fun ((d : Config.domain), (l : P.totp_listing)) ->
              List.iter
                (fun (r : P.totp_row) ->
                  say "%s  %2ds  %s%s%s  %s" (grouped r.code) r.seconds_left
                    r.issuer
                    (if r.issuer = "" || r.account = "" then "" else " / ")
                    r.account
                    (dname d ^ " " ^ r.id))
                l.rows;
              List.iter
                (fun id ->
                  prerr_endline
                    ("tsync: " ^ dname d ^ " " ^ id ^ " does not open"))
                l.corrupt)
            (each ?name config (fun d -> Vault_cmds.ask d (P.Totp_list filter)));
          0)
      $ filter)

let code_cmd =
  verb "code"
    ~doc:"Print one record's current code, for a script or a clipboard tool."
    Term.(
      const (fun id ?name config ->
          let c = Vault_cmds.ask (holder ?name config id) (P.Totp_code id) in
          say "%s" c.code;
          0)
      $ id_arg)

let rename_cmd =
  let issuer =
    Arg.(
      value
      & opt (some string) None
      & info ["issuer"] ~docv:"TEXT" ~doc:"The new issuer.")
  and account =
    Arg.(
      value
      & opt (some string) None
      & info ["account"] ~docv:"TEXT" ~doc:"The new account.")
  in
  verb "rename" ~doc:"Change a record's issuer or account."
    Term.(
      const (fun id issuer account ?name config ->
          if issuer = None && account = None then
            Fail.invalid "give --issuer, --account or both";
          Vault_cmds.ask (holder ?name config id)
            (P.Totp_rename { id; issuer; account });
          0)
      $ id_arg $ issuer $ account)

let remove_cmd =
  verb "remove" ~doc:"Remove a record."
    Term.(
      const (fun id ?name config ->
          Vault_cmds.ask (holder ?name config id) (P.Totp_remove id);
          0)
      $ id_arg)

let import_cmd =
  let file =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"FILE"
          ~doc:
            "A plain-text export, one otpauth URI per line; - reads standard \
             input.")
  in
  verb "import"
    ~doc:"Add every seed of another authenticator's plain-text export."
    Term.(
      const (fun file ?name config ->
          let text =
            if file = "-" then In_channel.input_all stdin
            else In_channel.with_open_bin file In_channel.input_all
          in
          let d = write_domain ?name config in
          let r = Vault_cmds.ask d (P.Totp_import text) in
          List.iter
            (fun (line, reason) ->
              prerr_endline (Printf.sprintf "tsync: line %d: %s" line reason))
            r.refused;
          say "%s: %d added, %d already there, %d refused" (dname d) r.added
            r.already (List.length r.refused);
          if r.refused = [] then 0 else 1)
      $ file)

let export_cmd =
  let stdin =
    Arg.(
      value & flag
      & info ["stdin"]
          ~doc:
            "Read each domain's passphrase from standard input, one line each.")
  in
  verb "export"
    ~doc:
      "Print every seed as an otpauth URI, the way out of tsync; asks each \
       domain's passphrase."
    Term.(
      const (fun stdin ?name config ->
          List.iter
            (fun (_, uris) -> List.iter (say "%s") uris)
            (each ?name config (fun d ->
                 let passphrase =
                   Vault_cmds.read_passphrase
                     ~prompt:(Printf.sprintf "passphrase of %s" (dname d))
                     ~stdin ()
                 in
                 Vault_cmds.ask d (P.Totp_export passphrase)));
          0)
      $ stdin)

let cmds =
  [
    Cmd.group
      (Cmd.info "totp"
         ~doc:"One-time-password seeds kept in the domain's vault.")
      [
        add_cmd;
        import_cmd;
        list_cmd;
        code_cmd;
        rename_cmd;
        remove_cmd;
        export_cmd;
      ];
  ]
