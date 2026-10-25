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

(* vault §3 step 4: shown once; afterwards only the kit shows it. *)
let show_secret (s : P.secret) =
  say "%s" s.secret_key;
  prerr_endline
    ("this is the secret key of vault " ^ s.key_id
   ^ ": keep it with your passphrase, which a new machine needs too; only \
      tsync vault kit shows it again")

let kit_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["kit"] ~docv:"FILE"
        ~doc:
          "Also write the emergency kit, a page to print, at $(docv); it holds \
           the secret key, so print it and delete the file.")

(* vault §3.1: a page that holds the secret key in plain text. *)
let write_kit dom path (s : P.secret) =
  Vault_kit.write ~path
    ~domain:(Domain_name.to_string dom.Tsync_config.Config.name)
    (`Emergency s.secret_key);
  prerr_endline
    ("wrote " ^ path ^ ": print it, keep the paper, and delete the file")

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

(* vault §2.3: six words, shown once for the user to write down. *)
let generated () =
  let passphrase = Tsync_vault.Words.passphrase 6 in
  say "%s" passphrase;
  prerr_endline
    "this is the vault's new passphrase: write it down; tsync never shows it \
     again";
  passphrase

let generate_arg =
  Arg.(
    value & flag
    & info ["generate"]
        ~doc:
          "Generate the new passphrase, six words, instead of asking for one.")

(* vault §2.2: a new passphrase is asked twice on a terminal. *)
let new_passphrase ?(generate = false) ~stdin () =
  if generate then generated ()
  else (
    let first = read_passphrase ~prompt:"new passphrase" ~stdin () in
    if (not stdin) && Unix.isatty Unix.stdin then (
      let again = read_passphrase ~prompt:"new passphrase, again" ~stdin () in
      if again <> first then Fail.invalid "the two passphrases differ");
    first)

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
      const (fun generate kit stdin dom ->
          let s = ask dom (P.Vault_init (new_passphrase ~generate ~stdin ())) in
          show_secret s;
          Option.iter (fun path -> write_kit dom path s) kit;
          0)
      $ generate_arg $ kit_arg
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
            if (ask dom (P.Vault_status `Auto)).enrolled then None
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
          ask dom (P.Vault_lock (if forget then `Forget else `Lock));
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
      const (fun new_secret_key generate stdin dom ->
          let passphrase = new_passphrase ~generate ~stdin () in
          (match
             ask dom (P.Vault_passphrase { passphrase; new_secret_key })
           with
            | Some s -> show_secret s
            | None -> say "passphrase changed");
          0)
      $ new_secret_key $ generate_arg
      $ stdin_flag "the new passphrase")

let rekey_cmd =
  let change =
    Arg.(
      value & flag
      & info ["new-passphrase"]
          ~doc:"Also choose a new passphrase; advised when a machine was lost.")
  in
  verb "rekey"
    ~doc:
      "Replace the vault's key and secret key, re-encrypting every record: how \
       a lost machine is shut out. Every other machine then needs the new \
       secret key."
    Term.(
      const (fun change generate kit stdin dom ->
          let passphrase = read_passphrase ~stdin () in
          let new_passphrase =
            if change || generate then Some (new_passphrase ~generate ~stdin ())
            else None
          in
          let r = ask dom (P.Vault_rekey { passphrase; new_passphrase }) in
          show_secret r.secret;
          Option.iter (fun path -> write_kit dom path r.secret) kit;
          Option.iter
            (fun reason ->
              prerr_endline
                ("re-encrypting the records stopped (" ^ reason
               ^ "): unlock this machine again to finish"))
            r.pending;
          0)
      $ change $ generate_arg $ kit_arg
      $ stdin_flag "the passphrase, then the new one")

let kit_cmd =
  let output =
    Arg.(
      required
      & opt (some string) None
      & info ["output"] ~docv:"FILE" ~doc:"Where to write the page.")
  in
  verb "kit"
    ~doc:
      "Write the vault's emergency kit, a page to print with the secret key as \
       text and as a QR code; asks for the passphrase."
    Term.(
      const (fun output stdin dom ->
          write_kit dom output
            (ask dom (P.Vault_kit (read_passphrase ~stdin ())));
          0)
      $ output
      $ stdin_flag "the passphrase")

(* vault §8.2: the owner writes and reads the file, so a path is made absolute
   here, where the user's directory is. *)
let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let say_carried what (c : P.carried) =
  say "%s %d records and %d keys" what c.records c.keys;
  List.iter
    (say "left out: %s, which opens under no key this vault holds")
    c.skipped

let export_cmd =
  let output =
    Arg.(
      required
      & opt (some string) None
      & info ["output"] ~docv:"FILE" ~doc:"Where to write the export.")
  in
  verb "export"
    ~doc:
      "Write every record of the vault, its keys and its appearance to one \
       file, sealed with the passphrase and this machine's secret key; asks \
       for the passphrase."
    Term.(
      const (fun output stdin dom ->
          say_carried "exported"
            (ask dom
               (P.Vault_export
                  {
                    passphrase = read_passphrase ~stdin ();
                    path = absolute output;
                  }));
          prerr_endline
            "it opens with this passphrase and secret key: keep the emergency \
             kit that holds them";
          0)
      $ output
      $ stdin_flag "the passphrase")

let import_cmd =
  let file =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"FILE" ~doc:"An export, or a scheduled backup.")
  in
  let backup =
    Arg.(
      value & flag
      & info ["backup-key"]
          ~doc:"The file is a scheduled backup: ask for its backup key.")
  in
  verb "import"
    ~doc:
      "Put an export's records, keys and appearance into this domain's vault, \
       which must be new and empty; asks for the passphrase and secret key it \
       was sealed with, or its backup key."
    Term.(
      const (fun file backup stdin dom ->
          let unseal =
            if backup then
              `Backup_key (read_passphrase ~prompt:"backup key" ~stdin ())
            else (
              let passphrase =
                read_passphrase ~prompt:"the export's passphrase" ~stdin ()
              in
              `Vault
                (passphrase, read_passphrase ~prompt:"its secret key" ~stdin ()))
          in
          say_carried "imported"
            (ask dom (P.Vault_import { path = absolute file; unseal }));
          0)
      $ file $ backup
      $ stdin_flag "the passphrase then the secret key, or the backup key,")

let backup_key_cmd =
  let kit =
    Arg.(
      value
      & opt (some string) None
      & info ["kit"] ~docv:"FILE"
          ~doc:
            "Also write the backup kit, a page to print, at $(docv); it holds \
             the backup key, so print it and delete the file.")
  in
  verb "backup-key"
    ~doc:
      "Make the vault a new backup key, which scheduled backups are sealed to; \
       shows its private half once, which no machine keeps."
    Term.(
      const (fun kit dom ->
          let s = ask dom P.Vault_backup_key in
          say "%s" s.secret_key;
          prerr_endline
            ("this is backup key " ^ s.key_id
           ^ ": it opens the scheduled backups and nothing else; keep it away \
              from your computers, as no machine keeps it and tsync never \
              shows it again");
          Option.iter
            (fun path ->
              Vault_kit.write ~path
                ~domain:(Domain_name.to_string dom.Tsync_config.Config.name)
                (`Backup (s.secret_key, s.key_id));
              prerr_endline
                ("wrote " ^ path
               ^ ": print it, keep the paper, and delete the file"))
            kit;
          0)
      $ kit)

let machines_cmd =
  let name =
    Arg.(
      value
      & opt (some string) None
      & info ["name"] ~docv:"NAME" ~doc:"Rename this machine in the list.")
  in
  let date t =
    let tm = Unix.localtime (float_of_int t) in
    Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
      tm.tm_mday
  in
  verb "machines"
    ~doc:
      "The machines enrolled in the vault: informative, a re-key is what shuts \
       one out."
    Term.(
      const (fun name dom ->
          List.iter
            (fun (m : P.machine) ->
              match m.entry with
                | Some e ->
                    say "%s%s  enrolled %s, last unlocked %s" e.name
                      (if m.this then " (this machine)" else "")
                      (date e.enrolled) (date e.last_unlock)
                | None -> say "%s  does not open under this key" m.uuid)
            (ask dom (P.Vault_machines name));
          0)
      $ name)

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
         let s = ask dom (P.Vault_status `Auto) in
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
         if s.secret_key_replaced then
           say
             "secret key: replaced elsewhere (a re-key or a new one); unlock \
              with the new one";
         List.iter
           (say "new machine: %s (tsync vault machines lists them)")
           s.new_machines;
         Option.iter
           (fun (a : P.auto_lock) ->
             let from part =
               match List.assoc_opt part a.from with
                 | Some "main" -> " (from the main)"
                 | _ -> ""
             in
             let parts =
               List.filter_map Fun.id
                 [
                   Option.map
                     (fun n ->
                       Printf.sprintf "after %d min idle%s" n
                         (from "idleMinutes"))
                     a.policy.idle_minutes;
                   (if a.policy.on_screen_lock then
                      Some ("on screen lock" ^ from "onScreenLock")
                    else None);
                   Option.map
                     (fun n ->
                       Printf.sprintf "%d h after unlock%s" n (from "maxHours"))
                     a.policy.max_hours;
                 ]
             in
             say "auto-lock: %s" (String.concat ", " parts))
           s.auto_lock;
         Option.iter
           (fun r ->
             say "locked by auto-lock: %s"
               (match r with
                 | `Idle -> "idle"
                 | `Screen -> "screen locked"
                 | `Age -> "unlocked too long"))
           s.locked_by;
         List.iter (fun (kind, n) -> say "slots: %d %s" n kind) s.slots;
         List.iter
           (say "unusable slot: %s (past the readers' limits)")
           s.unusable;
         if s.retired > 0 then say "retired keys: %d" s.retired;
         List.iter
           (say
              "retired key: %s does not unwrap; the files under it do not open")
           s.retired_unreadable;
         List.iter (say "keyring copy: %s") s.copies;
         Option.iter (say "backup key: %s") s.backup_key;
         Option.iter
           (fun (b : P.backup_state) ->
             say "backups: every %d h to %s, %s%s" b.every_hours b.dir
               (match b.last with
                 | Some at ->
                     let tm = Unix.localtime at in
                     Printf.sprintf "the last %04d-%02d-%02d %02d:%02d"
                       (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour
                       tm.tm_min
                 | None -> "none yet")
               (if b.stale then " (overdue)" else "");
             Option.iter (say "backup not written: %s") b.error)
           s.backup;
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
        rekey_cmd;
        machines_cmd;
        kit_cmd;
        export_cmd;
        import_cmd;
        backup_key_cmd;
        delete_cmd;
        status_cmd;
        appearance_cmd;
      ];
  ]
