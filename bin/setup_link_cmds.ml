open Cmdliner
open Tsync_core
open Tsync_config
open Cli
module L = Tsync_setup_link.Setup_link

let field name (b : Config.backend) =
  match List.assoc_opt name b.fields with Some (S s) -> Some s | _ -> None

let trim_slash u =
  if String.ends_with ~suffix:"/" u then String.sub u 0 (String.length u - 1)
  else u

(* A store reached the way a joining machine will reach it. *)
let proxy_store name (b : L.backend) =
  (Option.get (Tsync_store.Driver.find "http-proxy")).create ~domain:name
    ~admission:Tsync_store.Uplink.none ~name:b.name
    [("url", S b.url); ("secret", S b.secret)]

(* setup-link §6.2: a signed request the server answers only for a domain it
   serves with that secret. *)
let check_served name (b : L.backend) =
  ignore ((proxy_store name b).head_opt (Key.cursor name))

let served_bindings config =
  match Tsync_http_proxy.Proxy_options.resolve config with
    | Some (_, bindings) -> bindings
    | None -> []

let binding_of bindings (d : Config.domain) =
  List.find_opt
    (fun (b : Tsync_http_proxy.Proxy_options.binding) ->
      Domain_name.equal b.domain.name d.name)
    bindings

(* setup-link §5.1 step 2. *)
let shared_backend ~url bindings (d : Config.domain) =
  let name = Domain_name.to_string d.name in
  match binding_of bindings d with
    | Some binding -> (
        match url with
          | Some url ->
              {
                L.name = "server";
                url = trim_slash url;
                secret = binding.secret;
              }
          | None ->
              refuse
                "%s is served by this machine; give the address clients reach \
                 it at with --url"
                name)
    | None -> (
        match
          List.find_opt
            (fun (b : Config.backend) ->
              b.btype = "http-proxy" && (b.role = Main || b.role = Replica))
            d.backends
        with
          | Some b -> (
              match (field "url" b, field "secret" b) with
                | Some url, Some secret ->
                    { L.name = b.bname; url = trim_slash url; secret }
                | _ ->
                    refuse "%s: its %s backend has no url or secret" name
                      b.bname)
          | None ->
              refuse
                "%s is neither served by this machine nor reached through a \
                 tsync server"
                name)

(* setup-link §4: the extensions a joining machine follows are those its
   server states, and a vault's look is the owner's to read. *)
let describe config (d : Config.domain) backend =
  let stated =
    ((proxy_store d.name backend).capabilities (Key.domain_prefix d.name))
      .domain_settings
  in
  let extensions =
    Config.extensions_in_force { d with extensions = None } stated
  in
  let vault =
    if extensions = [] then None
    else (
      match
        (Tsync_owner.Owner.request ~what:"tsync config share" config d
           (Tsync_owner.Protocol.Vault_status `Never))
          .appearance
      with
        | Some a -> Some { L.color = a.color; icon = a.icon }
        | None -> None
        | exception Fail.E f ->
            Log.debug "vault appearance of %s: %s"
              (Domain_name.to_string d.name)
              f.reason;
            None)
  in
  { L.name = d.name; extensions; vault }

let create config names url expires =
  let names = List.sort_uniq compare names in
  if List.length names > L.max_domains then
    refuse "a setup link holds at most %d domains" L.max_domains;
  let domains =
    List.map
      (fun n ->
        match Config.find_domain config n with
          | Some d -> d
          | None -> refuse "no domain %s in the config" n)
      names
  in
  let bindings = served_bindings config in
  if
    url <> None
    && not (List.exists (fun d -> binding_of bindings d <> None) domains)
  then refuse "--url is for a domain this machine serves, and none of these is";
  let shared =
    List.map (fun d -> (d, shared_backend ~url bindings d)) domains
  in
  List.iter (fun ((d : Config.domain), b) -> check_served d.name b) shared;
  let about = List.map (fun (d, b) -> describe config d b) shared in
  let (first : Config.domain), first_backend = List.hd shared in
  let link, stored =
    L.create ~base:first_backend.url
      ~expires:(Unix.gettimeofday () +. expires)
      ~from:config.client_name ~about
      (List.map
         (fun ((d : Config.domain), b) -> { L.name = d.name; backends = [b] })
         shared)
  in
  let store = proxy_store first.name first_backend in
  let key = Option.get (Key.share link.token) in
  (match
     store.put_if_absent key (Bigstring.of_string (L.stored_to_string stored))
   with
    | Won -> ()
    | Held _ -> fail "the generated token is taken; try again");
  (* setup-link §5.1: a server that stores the manifest but has no /join/ is
     one that predates setup links. *)
  (match L.fetch link with
    | Ok _ -> ()
    | Error _ ->
        ignore (store.delete key);
        fail "%s is too old to hold setup links" first_backend.url);
  print_endline (L.link_to_string link);
  prerr_endline ("expires " ^ Narrate.date stored.expires);
  prerr_endline
    (Printf.sprintf "Anyone with this link can reach %s until then."
       (String.concat ", " names));
  0

(* setup-link §5.2: only a secret of the domain the manifest names deletes it. *)
let revoke config text =
  let link =
    match L.link_of_string text with Ok l -> l | Error e -> refuse "%s" e
  in
  let key = Option.get (Key.share link.token) in
  let bindings = served_bindings config in
  let candidates =
    List.filter_map
      (fun (d : Config.domain) ->
        match binding_of bindings d with
          | Some b ->
              Some (d, { L.name = "server"; url = link.base; secret = b.secret })
          | None ->
              List.find_map
                (fun (b : Config.backend) ->
                  match (b.btype, field "url" b, field "secret" b) with
                    | "http-proxy", Some url, Some secret
                      when trim_slash url = link.base ->
                        Some (d, { L.name = b.bname; url = link.base; secret })
                    | _ -> None)
                d.backends)
      config.domains
  in
  let held ((d : Config.domain), b) =
    let store = proxy_store d.name b in
    match store.get_opt key with
      | Some _ -> store.delete key
      | None -> false
      | exception Fail.E f ->
          Log.debug "revoke through %s: %s"
            (Domain_name.to_string d.name)
            f.reason;
          false
  in
  if List.exists held candidates then (
    say "revoked";
    0)
  else (
    say "no domain configured here holds that link";
    1)

let share names url expires revoke_link verbose =
  set_verbose verbose;
  run (fun () ->
      let config = config () in
      match (revoke_link, names) with
        | Some link, [] -> revoke config link
        | Some _, _ :: _ -> refuse "--revoke takes no domain"
        | None, [] -> refuse "name the domains to share"
        | None, names ->
            create config names url
              (Option.value ~default:L.default_expiry expires))

let share_cmd =
  let names =
    Arg.(
      value & pos_all string []
      & info [] ~docv:"DOMAIN" ~doc:"A domain to share.")
  and url =
    Arg.(
      value
      & opt (some string) None
      & info ["url"] ~docv:"URL"
          ~doc:
            "The address clients reach this machine's server at, for a domain \
             it serves.")
  and expires =
    Arg.(
      value
      & opt (some duration) None
      & info ["expires"] ~docv:"DUR"
          ~doc:"How long the link lives (7d by default).")
  and revoke_link =
    Arg.(
      value
      & opt (some string) None
      & info ["revoke"] ~docv:"LINK" ~doc:"Revoke a setup link.")
  in
  cmd "share"
    ~doc:"Create a link that sets up these domains on another machine."
    Term.(const share $ names $ url $ expires $ revoke_link $ verbose)

let backend_json role (b : L.backend) =
  `Assoc
    [
      ("type", `String "http-proxy");
      ("name", `String b.name);
      ("role", `String role);
      ("url", `String b.url);
      ("secret", `String b.secret);
    ]

let same_server (existing : Config.domain) (d : L.domain) =
  List.exists
    (fun (b : Config.backend) ->
      List.exists
        (fun (n : L.backend) ->
          Option.map trim_slash (field "url" b) = Some n.url)
        d.backends)
    existing.backends

type outcome = Added of Yojson.Safe.t | Already | Failed

(* setup-link §6.2, one domain of the payload. *)
let consider current (entry : L.entry) =
  match entry with
    | Unusable { name; reason } ->
        say "%s: skipped, %s" name reason;
        Failed
    | Joinable d -> (
        let name = Domain_name.to_string d.name in
        match Option.bind current (fun c -> Config.find_domain c name) with
          | Some existing when same_server existing d ->
              say "%s: already set up" name;
              Already
          | Some _ ->
              say "%s: refused, a domain of that name uses another server here"
                name;
              Failed
          | None -> (
              match List.iter (check_served d.name) d.backends with
                | () ->
                    Added
                      (Config_wizard.joined_domain ~name
                         (List.mapi
                            (fun i b ->
                              backend_json
                                (if i = 0 then "main" else "replica")
                                b)
                            d.backends))
                | exception Fail.E f ->
                    say "%s: %s" name f.reason;
                    Failed))

let join text verbose =
  set_verbose verbose;
  run (fun () ->
      let link =
        match L.link_of_string text with Ok l -> l | Error e -> refuse "%s" e
      in
      let payload =
        match Result.bind (L.fetch link) (L.open_ link) with
          | Ok p -> p
          | Error e -> fail "%s" e
      in
      if payload.from <> "" then say "From %s:" payload.from;
      let path = Paths.config_file () in
      let raw =
        Option.map
          (fun text ->
            match Yojson.Safe.from_string text with
              | `Assoc _ as j -> j
              | _ | (exception Yojson.Json_error _) ->
                  fail "%s is not a JSON object; fix it by hand first" path)
          (Fs.read_file_opt path)
      in
      let current = config_opt () in
      let outcomes = List.map (consider current) payload.entries in
      let added =
        List.filter_map (function Added j -> Some j | _ -> None) outcomes
      in
      if added <> [] then (
        let j = Option.value ~default:(Config_wizard.new_config ()) raw in
        let domains =
          match j with
            | `Assoc l -> (
                match List.assoc_opt "domains" l with
                  | Some (`List d) -> d
                  | _ -> [])
            | _ -> []
        in
        let j =
          match j with
            | `Assoc l ->
                `Assoc
                  (List.remove_assoc "domains" l
                  @ [("domains", `List (domains @ added))])
            | j -> j
        in
        match Config_wizard.write j with
          | Error e -> fail "not written: %s" e
          | Ok config ->
              List.iter
                (fun d ->
                  match d with
                    | `Assoc l -> (
                        match List.assoc_opt "name" l with
                          | Some (`String n) -> (
                              match
                                Option.bind
                                  (Config.find_domain config n)
                                  Mounts.configured
                              with
                                | Some at -> say "%s: added, at %s" n at
                                | None -> say "%s: added" n)
                          | _ -> ())
                    | _ -> ())
                added;
              say "written to %s; restart the tsync service to apply it" path);
      if List.for_all (function Failed -> false | _ -> true) outcomes then 0
      else 1)

let join_cmd =
  let link =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"LINK" ~doc:"The setup link.")
  in
  cmd "join" ~doc:"Add the domains of a setup link to this machine's config."
    Term.(const join $ link $ verbose)
