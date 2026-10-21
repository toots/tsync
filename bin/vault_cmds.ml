open Cmdliner
open Tsync_core
open Cli
module P = Tsync_owner.Protocol

(* extensions README §6: K lives in the owner's memory, so no command takes
   ownership for its run. *)
let ask dom req =
  try Tsync_owner.Owner.ask dom req
  with Tsync_ipc.Ipc.Not_serving _ ->
    Fail.raise_ Unreachable ~repair:"start it with tsync start"
      "no owner of %s is running"
      (Domain_name.to_string dom.Tsync_config.Config.name)

let verb name ~doc term =
  cmd name ~doc
    Term.(
      const (fun f name verbose ->
          set_verbose verbose;
          run (fun () -> f (domain ?name (config ()))))
      $ term $ domain_arg $ verbose)

(* vault §3 step 4: shown once. *)
let show_secret (s : P.secret) =
  say "%s" s.secret_key;
  prerr_endline
    ("this is the secret key of vault " ^ s.key_id
   ^ ": keep it with your passphrase; tsync never shows it again, and a new \
      machine needs both")

let read_passphrase ?(prompt = "passphrase") ~stdin () =
  if stdin || not (Unix.isatty Unix.stdin) then
    In_channel.input_line In_channel.stdin |> Option.value ~default:""
  else (
    print_string (prompt ^ ": ");
    flush stdout;
    let saved = Unix.tcgetattr Unix.stdin in
    Unix.tcsetattr Unix.stdin TCSANOW { saved with c_echo = false };
    Fun.protect
      ~finally:(fun () ->
        Unix.tcsetattr Unix.stdin TCSANOW saved;
        print_newline ())
      (fun () ->
        Option.value ~default:"" (In_channel.input_line In_channel.stdin)))

(* vault §2.2: a new passphrase is asked twice on a terminal. *)
let new_passphrase ~stdin () =
  let first = read_passphrase ~prompt:"new passphrase" ~stdin () in
  if (not stdin) && Unix.isatty Unix.stdin then (
    let again = read_passphrase ~prompt:"new passphrase, again" ~stdin () in
    if again <> first then Fail.invalid "the two passphrases differ");
  first

let stdin_flag what =
  Arg.(
    value & flag
    & info ["stdin"]
        ~doc:("Read " ^ what ^ " from standard input, one line each."))

let init_cmd =
  verb "init"
    ~doc:
      "Create the domain's vault under your passphrase, and show its secret \
       key once."
    Term.(
      const (fun stdin dom ->
          show_secret (ask dom (P.Vault_init (new_passphrase ~stdin ())));
          0)
      $ stdin_flag "the passphrase")

let unlock_cmd =
  verb "unlock"
    ~doc:
      "Unlock the domain's vault with your passphrase, and the secret key on a \
       new machine."
    Term.(
      const (fun stdin dom ->
          let passphrase = read_passphrase ~stdin () in
          (* vault §6: only a machine not enrolled is asked for the secret key. *)
          let secret_key =
            if (ask dom P.Vault_status).enrolled then None
            else Some (read_passphrase ~prompt:"secret key" ~stdin ())
          in
          ask dom (P.Vault_unlock { passphrase; secret_key });
          say "unlocked";
          0)
      $ stdin_flag "the passphrase, then the secret key if needed,")

let lock_cmd =
  let forget =
    Arg.(
      value & flag
      & info ["forget"]
          ~doc:
            "Also forget the secret key: the next unlock here needs it again.")
  in
  verb "lock" ~doc:"Forget the domain's vault key on this machine."
    Term.(
      const (fun forget dom ->
          ask dom (P.Vault_lock forget);
          say "locked";
          0)
      $ forget)

let passphrase_cmd =
  let new_secret_key =
    Arg.(
      value & flag
      & info ["new-secret-key"]
          ~doc:
            "Also draw a new secret key, shown once; every other machine then \
             needs it.")
  in
  verb "passphrase"
    ~doc:"Replace the vault's passphrase with a new one you choose."
    Term.(
      const (fun new_secret_key stdin dom ->
          let passphrase = new_passphrase ~stdin () in
          (match
             ask dom (P.Vault_passphrase { passphrase; new_secret_key })
           with
            | Some s -> show_secret s
            | None -> say "passphrase changed");
          0)
      $ new_secret_key
      $ stdin_flag "the new passphrase")

let delete_cmd =
  verb "delete"
    ~doc:"Delete the domain's vault and every record in it, for good."
    (Term.const (fun dom ->
         let name = Domain_name.to_string dom.Tsync_config.Config.name in
         prerr_endline
           ("this deletes the vault of " ^ name
          ^ " and every record in it, on every machine");
         print_string ("type " ^ name ^ " to confirm: ");
         flush stdout;
         let typed =
           Option.value ~default:"" (In_channel.input_line In_channel.stdin)
         in
         (match ask dom (P.Vault_delete (String.trim typed)) with
           | None -> ()
           | Some reason ->
               prerr_endline
                 ("tsync: this machine's keystore entry is left: " ^ reason
                ^ "; remove the item \"tsync vault key\" in Keychain Access"));
         say "deleted";
         0))

let status_cmd =
  verb "status" ~doc:"Whether the vault exists and is unlocked, and its slots."
    (Term.const (fun dom ->
         let s = ask dom P.Vault_status in
         say "vault: %s"
           (match s.vault with
             | `Absent -> "none"
             | `Corrupt reason -> "corrupt (" ^ reason ^ ")"
             | `Locked -> "locked"
             | `Unlocked -> "unlocked");
         Option.iter (say "key: %s") s.key_id;
         Option.iter (say "cached: %s") s.cached;
         if s.key_id <> None then
           say "this machine: %s"
             (if s.enrolled then "enrolled"
              else "not enrolled (needs the secret key)");
         Option.iter (say "keystore not used: %s") s.keystore_error;
         List.iter (fun (kind, n) -> say "slots: %d %s" n kind) s.slots;
         List.iter
           (say "unusable slot: %s (past the readers' limits)")
           s.unusable;
         List.iter (say "keyring copy: %s") s.copies;
         Option.iter
           (fun (a : P.appearance) ->
             say "colour: %s%s" a.color
               (if a.color_chosen then "" else " (from the key id)");
             say "icon: %s"
               (match a.icon with
                 | Some png -> Printf.sprintf "%d-byte PNG" (String.length png)
                 | None -> "none (the tsync icon in the colour)"))
           s.appearance;
         0))

(* vault §8.1 *)
(* vault §8.1: the stored form as it is, otherwise converted by this build when
   it can; the owner accepts only the stored form. *)
let icon_of source =
  let module A = Tsync_vault.Appearance in
  let is_url =
    String.starts_with ~prefix:"https://" source
    || String.starts_with ~prefix:"http://" source
  in
  let given =
    if is_url then None
    else Some (In_channel.with_open_bin source In_channel.input_all)
  in
  match (given, Atomic.get Icon_image.converter) with
    | Some icon, _ when Result.is_ok (A.check_icon icon) -> icon
    | _, Some convert ->
        convert ~max_side:A.icon_max_side ~max_bytes:A.icon_max_bytes
          ~deadline:(Rt.now () +. 30.)
          source
    | Some icon, None -> (
        match A.check_icon icon with
          | Ok icon -> icon
          | Error why ->
              Fail.invalid
                "%s; this build converts no image: give a square PNG of at \
                 most %d pixels and %d KiB"
                why A.icon_max_side (A.icon_max_bytes / 1024))
    | None, None -> Fail.invalid "this build fetches no image: give a file"

let appearance_cmd =
  let color =
    Arg.(
      value
      & opt (some string) None
      & info ["color"] ~docv:"#RRGGBB" ~doc:"The vault's colour.")
  and default_color =
    Arg.(
      value & flag
      & info ["default-color"] ~doc:"Go back to the colour the key id gives.")
  and icon =
    Arg.(
      value
      & opt (some string) None
      & info ["icon"] ~docv:"IMAGE"
          ~doc:
            "An image file or an http(s) URL, shown in place of the tsync \
             icon: its centre square, scaled to at most 256 pixels and kept as \
             a PNG of at most 64 KiB. A build without FFmpeg takes only a PNG \
             already in that form.")
  and no_icon =
    Arg.(
      value & flag
      & info ["no-icon"] ~doc:"Show the tsync icon in the colour again.")
  in
  verb "appearance"
    ~doc:
      "Set how the vault looks in pickers: a colour, and an icon in place of \
       tsync's."
    Term.(
      const (fun color default_color icon no_icon dom ->
          let pick ~set ~clear what =
            match (set, clear) with
              | Some v, false -> `Set v
              | None, true -> `Clear
              | None, false -> `Keep
              | Some _, true ->
                  Fail.invalid "give --%s or its opposite, not both" what
          in
          let set_icon =
            pick ~set:(Option.map icon_of icon) ~clear:no_icon "icon"
          in
          ask dom
            (P.Vault_appearance
               {
                 set_color = pick ~set:color ~clear:default_color "color";
                 set_icon;
               });
          0)
      $ color $ default_color $ icon $ no_icon)

let cmds =
  [
    Cmd.group
      (Cmd.info "vault" ~doc:"The domain's vault, shared by its extensions.")
      [
        init_cmd;
        unlock_cmd;
        lock_cmd;
        passphrase_cmd;
        delete_cmd;
        status_cmd;
        appearance_cmd;
      ];
  ]
