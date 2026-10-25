(* vault §8.2 and §8.3 through a real owner and the CLI given as argv 1: a
   vault holding a code, a login linked to it, a note with a secret field and a
   passkey is exported, deleted, made again and imported, and every record, the
   appearance and the old K come back; then backed up on a schedule to a backup
   key, and restored from a backup. *)

open Tsync_core
open Tsync_ipc
module Owner = Tsync_owner.Owner
module Keystore = Tsync_owner.Keystore

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-export-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Tsync_config.Paths.owner_socket (Domain_name.v "docs")

let config_text =
  Printf.sprintf
    {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":["totp","passwords"],"frontends":["http-proxy"],
   "vaultBackup":{"dir":"%s/backups","everyHours":1,"keep":2},
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
    root root

let config = Tsync_config.Config.of_string config_text
let () = Unix.putenv "TSYNC_CONFIG_JSON" config_text
let tsync_bin = Sys.argv.(1)
let file name = Filename.concat root name
let passphrase = "correct horse battery staple"
let second = "a second passphrase, longer"
let seed = "JBSWY3DPEHPK3PXP"

(* [s] with every [sub] replaced by [by]. *)
let rec replace_all ~sub ~by s =
  let n = String.length sub in
  let rec find i =
    if i + n > String.length s then None
    else if String.sub s i n = sub then Some i
    else find (i + 1)
  in
  match find 0 with
    | None -> s
    | Some i ->
        String.sub s 0 i ^ by
        ^ replace_all ~sub ~by (String.sub s (i + n) (String.length s - i - n))

(* A refusal's line, with what changes from run to run masked. *)
let masked line =
  let line = replace_all ~sub:root ~by:"ROOT" line in
  match String.index_opt line '(' with
    | Some i when i + 20 <= String.length line && String.sub line i 4 = "(id "
      ->
        String.sub line 0 (i + 4)
        ^ "ID"
        ^ String.sub line (i + 20) (String.length line - i - 20)
    | _ -> line

(* The CLI run with [input] on its standard input: [ok], or its error. *)
let cli args input =
  let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
  let err_read, err_write = Unix.pipe ~cloexec:true () in
  let out_read, out_write = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process tsync_bin
      (Array.of_list (tsync_bin :: args))
      stdin_read out_write err_write
  in
  List.iter Unix.close [stdin_read; out_write; err_write];
  ignore (Unix.write_substring stdin_write input 0 (String.length input));
  Unix.close stdin_write;
  let out = In_channel.input_all (Unix.in_channel_of_descr out_read) in
  let err = In_channel.input_all (Unix.in_channel_of_descr err_read) in
  match Unix.waitpid [] pid with
    | _, WEXITED 0 -> "ok: " ^ String.trim out
    | _ -> (
        match
          List.find_opt
            (String.starts_with ~prefix:"tsync:")
            (String.split_on_char '\n' err)
        with
          | Some line -> masked line
          | None -> "failed: " ^ String.trim err)

let s v = `String v
let ask fields = Ipc.call socket (`Assoc (("domain", `String "docs") :: fields))
let field = Ipc.field
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let answer label r =
  match field r "error" with
    | Some e -> p "%-40s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-40s ok" label

let b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let unb64 s = Base64.decode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let rs_of_der der =
  let int_at i =
    let len = Char.code der.[i + 1] in
    let v = String.sub der (i + 2) len in
    let v =
      if String.length v > 32 then String.sub v (String.length v - 32) 32
      else String.make (32 - String.length v) '\000' ^ v
    in
    (v, i + 2 + len)
  in
  let r, next = int_at 2 in
  let s, _ = int_at next in
  (r, s)

let client_data_hash = String.make 32 'c'

(* passwords §7.4: the assertion verifies with the public key the creation
   gave. *)
let asserts ~key id =
  let r =
    ask
      [
        ("action", s "passwords_passkey_assert");
        ("origin", s "https://example.com");
        ("rpId", s "example.com");
        ("id", s id);
        ("clientDataHash", s (b64 client_data_hash));
      ]
  in
  match (field r "authenticatorData", field r "signature") with
    | Some a, Some signature ->
        let digest =
          Digestif.SHA256.(
            to_raw_string (digest_string (unb64 a ^ client_data_hash)))
        in
        Mirage_crypto_ec.P256.Dsa.verify ~key
          (rs_of_der (unb64 signature))
          digest
    | _ -> false

(* What a user sees of the vault, for comparing before and after. *)
let view ~login ~note =
  let get id = ask [("action", s "passwords_get"); ("id", s id)] in
  let l = get login and n = get note in
  let codes =
    match member (ask [("action", s "totp_list")]) "records" with
      | Some (`List rows) ->
          List.map
            (fun r ->
              Option.value ~default:"" (field r "id")
              ^ " "
              ^ Option.value ~default:"" (field r "issuer"))
            rows
      | _ -> []
  in
  Printf.sprintf "codes [%s]; login %s %s %s linked %s; note %s fields %s"
    (String.concat ", "
       (List.map
          (fun c ->
            if String.length c > 32 then String.sub c 33 (String.length c - 33)
            else c)
          codes))
    (Option.value ~default:"-" (field l "title"))
    (Option.value ~default:"-" (field l "username"))
    (if field l "password" = Some "hunter2 hunter2" then "its password"
     else "another password")
    (match field l "totp" with
      | Some id when List.exists (String.starts_with ~prefix:id) codes ->
          "to the code"
      | Some _ -> "to another"
      | None -> "to none")
    (Option.value ~default:"-" (field n "title"))
    (match member n "fields" with
      | Some j -> Yojson.Safe.to_string j
      | None -> "-")

let id_of label r =
  match field r "id" with
    | Some id -> id
    | None ->
        answer label r;
        ""

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let keystore : Keystore.t =
  let dir = file "keystore" in
  let path name =
    Filename.concat dir (String.map (function '/' -> '#' | c -> c) name)
  in
  {
    name = "test keystore";
    put =
      (fun ~domain ~key_id ~key ->
        Fs.mkdir_p dir;
        Fs.write_file_for_test (path domain) (key_id ^ key));
    get =
      (fun ~domain ->
        Option.map
          (fun s -> (String.sub s 0 16, String.sub s 16 (String.length s - 16)))
          (Fs.read_file_opt (path domain)));
    delete = (fun ~domain -> Fs.unlink_quiet (path domain));
  }

let status () = ask [("action", s "vault_status")]
let backup_dir = file "backups"

(* Another domain's backup in the same folder, whose name begins with this
   domain's and a hyphen. *)
let decoy = "docs-old-20991231T000000.000Z.tsync-vault-backup"

let backup_files () =
  match Sys.readdir backup_dir with
    | names ->
        List.sort compare (List.filter (( <> ) decoy) (Array.to_list names))
    | exception Sys_error _ -> []

let backup_state () =
  match member (status ()) "backup" with
    | Some b ->
        Printf.sprintf "overdue %b, error %s"
          (member b "stale" = Some (`Bool true))
          (Option.value ~default:"none" (field b "error"))
    | None -> "none"

let rec until ?(tries = 200) f =
  if f () || tries = 0 then f ()
  else (
    Rt.sleep 0.05;
    until ~tries:(tries - 1) f)

(* §8.3: a schedule needs a backup key; it writes while K is held, keeps the
   newest [keep], and a backup restores with the backup key alone. *)
let backups ~login ~note ~before =
  Fs.mkdir_p backup_dir;
  Fs.write_file_for_test (Filename.concat backup_dir decoy) "another domain's";
  ignore (until (fun () -> backup_state () <> "overdue true, error none"));
  p "%-40s %s, files %d" "no backup key yet" (backup_state ())
    (List.length (backup_files ()));
  let made = ask [("action", s "vault_backup_key")] in
  let seed = Option.get (field made "secretKey") in
  p "%-40s %b" "the backup key in status"
    (field (status ()) "backupKey" = field made "keyId");
  p "%-40s %b" "a backup written" (until (fun () -> backup_files () <> []));
  let first = List.hd (backup_files ()) in
  p "%-40s %b" "  mode 600"
    ((Unix.stat (Filename.concat backup_dir first)).st_perm land 0o777 = 0o600);
  p "%-40s %b" "  and later ones, the oldest removed"
    (until (fun () ->
         let now = backup_files () in
         List.length now = 2 && not (List.mem first now)));
  p "%-40s %s" "  status" (backup_state ());
  p "%-40s %b" "  another domain's backup left alone"
    (Sys.file_exists (Filename.concat backup_dir decoy));
  answer "lock" (ask [("action", s "vault_lock")]);
  let locked = backup_files () in
  Rt.sleep 0.5;
  p "%-40s %b" "locked, none written" (backup_files () = locked);
  let path = Filename.concat backup_dir (List.hd (List.rev locked)) in
  let import input =
    cli
      ["vault"; "import"; "--domain"; "docs"; "--stdin"; "--backup-key"; path]
      input
  in
  ignore (ask [("action", s "vault_unlock"); ("passphrase", s second)]);
  answer "delete" (ask [("action", s "vault_delete"); ("confirm", s "docs")]);
  ignore (ask [("action", s "vault_init"); ("passphrase", s passphrase)]);
  p "%-40s %s" "import a backup, another backup key"
    (import
       (Tsync_vault.Secret_key.to_string (Tsync_core.Ids.urandom 16) ^ "\n"));
  p "%-40s %s" "import a backup with its backup key" (import (seed ^ "\n"));
  p "%-40s %b" "after: the same records" (view ~login ~note = before);
  p "%-40s %b" "the backup key kept"
    (field (status ()) "backupKey" = field made "keyId")

let scenario () =
  let first = ask [("action", s "vault_init"); ("passphrase", s passphrase)] in
  let secret_key = Option.get (field first "secretKey") in
  let code =
    id_of "totp_add"
      (ask
         [
           ("action", s "totp_add");
           ( "uri",
             s ("otpauth://totp/ACME:john?secret=" ^ seed ^ "&issuer=ACME") );
         ])
  in
  let login =
    id_of "a login"
      (ask
         [
           ("action", s "passwords_add");
           ("title", s "GitHub");
           ("urls", `List [s "https://github.com"]);
           ("username", s "me@example.com");
           ("password", s "hunter2 hunter2");
           ("totp", s code);
         ])
  in
  let note =
    id_of "a note"
      (ask
         [
           ("action", s "passwords_add");
           ("kind", s "note");
           ("title", s "Wi-Fi");
           ("notes", s "the router");
           ( "fields",
             `List
               [
                 `Assoc
                   [
                     ("name", s "PIN");
                     ("value", s "1234");
                     ("secret", `Bool true);
                   ];
               ] );
         ])
  in
  let made =
    ask
      [
        ("action", s "passwords_passkey_create");
        ("origin", s "https://example.com");
        ("rpId", s "example.com");
        ("userHandle", s (b64 "user-1"));
        ("userName", s "me@example.com");
        ("userDisplayName", s "Me");
        ("algorithms", `List [`Int (-7)]);
        ("clientDataHash", s (b64 client_data_hash));
      ]
  in
  let passkey = id_of "a passkey" made in
  let key =
    match
      X509.Public_key.decode_der (unb64 (Option.get (field made "publicKey")))
    with
      | Ok (`P256 key) -> key
      | _ -> failwith "not a P-256 key"
  in
  answer "a colour"
    (ask [("action", s "vault_appearance"); ("color", s "#dc2626")]);
  let before = view ~login ~note in
  p "before: %s" before;
  let path = file "vault.export" in
  let export input =
    cli
      ["vault"; "export"; "--domain"; "docs"; "--stdin"; "--output"; path]
      input
  in
  p "%-40s %s" "export, a wrong passphrase" (export (second ^ "\n"));
  p "%-40s %b" "  and no file" (not (Sys.file_exists path));
  p "%-40s %s" "export" (export (passphrase ^ "\n"));
  let text = Fs.read_file path in
  p "%-40s mode %o" "  the file" ((Unix.stat path).st_perm land 0o777);
  p "%-40s %b" "  no password, seed or title in it"
    (not
       (List.exists
          (fun sub ->
            let n = String.length sub in
            let rec at i =
              i + n <= String.length text
              && (String.sub text i n = sub || at (i + 1))
            in
            at 0)
          ["hunter2"; seed; "GitHub"; "Wi-Fi"; "1234"]));
  p "%-40s %s" "export again, over the file" (export (passphrase ^ "\n"));
  let import ?(backup = false) input =
    cli
      (["vault"; "import"; "--domain"; "docs"; "--stdin"]
      @ (if backup then ["--backup-key"] else [])
      @ [path])
      input
  in
  p "%-40s %s" "import into this vault, not empty"
    (import (passphrase ^ "\n" ^ secret_key ^ "\n"));
  answer "delete" (ask [("action", s "vault_delete"); ("confirm", s "docs")]);
  let again = ask [("action", s "vault_init"); ("passphrase", s second)] in
  let new_secret_key = Option.get (field again "secretKey") in
  let key_id = Option.get (field (status ()) "keyId") in
  p "%-40s %s" "import, the new vault's secret key"
    (import (passphrase ^ "\n" ^ new_secret_key ^ "\n"));
  p "%-40s %s" "import, a wrong passphrase"
    (import (second ^ "\n" ^ secret_key ^ "\n"));
  p "%-40s %s" "import, as a backup" (import ~backup:true (secret_key ^ "\n"));
  p "%-40s %s" "import" (import (passphrase ^ "\n" ^ secret_key ^ "\n"));
  let after = view ~login ~note in
  p "%-40s %b" "after: the same records" (after = before);
  p "%-40s %b" "the code still answers"
    (member (ask [("action", s "totp_code"); ("id", s code)]) "secondsLeft"
    <> None);
  p "%-40s %b" "the passkey signs with its old key" (asserts ~key passkey);
  let st = status () in
  p "%-40s %s" "the colour"
    (match member st "appearance" with
      | Some a -> Option.value ~default:"-" (field a "color")
      | None -> "-");
  p "%-40s %b, retired %s" "the new K kept"
    (field st "keyId" = Some key_id)
    (match member st "retired" with
      | Some (`Int n) -> string_of_int n
      | _ -> "?");
  p "%-40s %s" "import again, now not empty"
    (import (passphrase ^ "\n" ^ secret_key ^ "\n"));
  backups ~login ~note ~before

let () =
  Keystore.register keystore;
  (* §8.3: an hour's period in 0.6 s. *)
  Atomic.set Tsync_owner.Vault.minute 0.01;
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      scenario ();
      ignore (ask [("action", s "stop")]);
      p "owner exit status %d" (Rt.Promise.await owner));
  Fs.rm_rf root
