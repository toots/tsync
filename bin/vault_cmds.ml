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
         0))

let cmds =
  [
    Cmd.group
      (Cmd.info "vault" ~doc:"The domain's vault, shared by its extensions.")
      [init_cmd; unlock_cmd; lock_cmd; passphrase_cmd; delete_cmd; status_cmd];
  ]
