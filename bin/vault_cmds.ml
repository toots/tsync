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
  say "%s" s.passphrase;
  prerr_endline
    ("key " ^ s.key_id
   ^ ": keep this passphrase; tsync never shows it again, and nothing recovers \
      the records without it")

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

let init_cmd =
  verb "init" ~doc:"Create the domain's vault and show its passphrase once."
    (Term.const (fun dom ->
         show_secret (ask dom P.Vault_init);
         0))

let unlock_cmd =
  let stdin =
    Arg.(
      value & flag
      & info ["stdin"] ~doc:"Read the passphrase from standard input.")
  in
  verb "unlock" ~doc:"Unlock the domain's vault with its passphrase."
    Term.(
      const (fun stdin dom ->
          ask dom (P.Vault_unlock (read_passphrase ~stdin ()));
          say "unlocked";
          0)
      $ stdin)

let lock_cmd =
  verb "lock" ~doc:"Forget the domain's vault key on this machine."
    (Term.const (fun dom ->
         ask dom P.Vault_lock;
         say "locked";
         0))

let passphrase_cmd =
  verb "passphrase"
    ~doc:"Replace the vault's passphrase with a new one, shown once."
    (Term.const (fun dom ->
         show_secret (ask dom P.Vault_passphrase);
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
      [init_cmd; unlock_cmd; lock_cmd; passphrase_cmd; status_cmd];
  ]
