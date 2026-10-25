(* The vault verbs (spec extensions/vault §3, §6–§8) through a serving owner:
   init, unlock, lock, passphrase change and status, on a domain that uses an
   extension and on one that does not. *)

open Tsync_core
open Tsync_ipc
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")

(* An owner holds its lock until its process exits: each owner runs in a
   child, [first ROOT] then [restart ROOT], the passphrase passed in ROOT. *)
let phase = if Array.length Sys.argv = 3 then Some Sys.argv.(1) else None

(* Short: on macOS the owner's socket lives under the home directory. *)
let root =
  match phase with
    | Some _ -> Sys.argv.(2)
    | None -> Printf.sprintf "/tmp/tsync-vault-%d" (Unix.getpid ())

let home = Filename.concat root "home"
let passphrase_file = Filename.concat root "passphrase"
let secret_key_file = Filename.concat root "secret-key"

let () =
  if phase = None then Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Filename.concat root "data/tsync/test.sock"

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":["totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]},
  {"name":"plain","symlinks":"keep","versioning":true,"extensions":[],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/plain"}]}]}|}
       root root)

let ask ?(domain = "docs") fields =
  Ipc.call socket
    (`Assoc
       (("domain", `String domain)
       :: List.map (fun (k, v) -> (k, `String v)) fields))

let field = Ipc.field

let answer label r =
  match field r "error" with
    | Some e -> p "%-32s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-32s ok" label

let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let status label =
  let r = ask [("action", "vault_status")] in
  match field r "error" with
    | Some _ -> answer label r
    | None ->
        p "%-34s %s%s%s%s slots=%s" label
          (Option.get (field r "vault"))
          (match member r "enrolled" with
            | Some (`Bool true) -> " enrolled"
            | _ -> " not-enrolled")
          (match field r "cached" with Some c -> " cached=" ^ c | None -> "")
          (match field r "keystoreError" with
            | Some e -> " keystore error: " ^ e
            | None -> "")
          (Yojson.Safe.to_string (Option.get (member r "slots")))

(* vault §2.1: 26 characters in groups 5-5-5-5-6. *)
let shape s =
  String.concat "-"
    (List.map
       (fun g -> string_of_int (String.length g))
       (String.split_on_char '-' s))

let secret label r =
  match field r "secretKey" with
    | Some s ->
        p "%-34s secret key %s, key id of %d hex" label (shape s)
          (String.length (Option.get (field r "keyId")));
        s
    | None ->
        answer label r;
        ""

let store_holds needle =
  let rec walk dir =
    Array.exists
      (fun n ->
        let path = Filename.concat dir n in
        if Sys.is_directory path then walk path
        else (
          let body = In_channel.with_open_bin path In_channel.input_all in
          let n = String.length needle in
          let rec at i =
            i + n <= String.length body
            && (String.sub body i n = needle || at (i + 1))
          in
          at 0))
      (Sys.readdir dir)
  in
  walk (Filename.concat root "store")

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let with_owner f =
  let owner =
    Rt.async (fun () ->
        Owner.run ~socket config config.Tsync_config.Config.domains)
  in
  wait_serving 100;
  f ();
  ignore (ask [("action", "stop")]);
  p "owner exit status %d" (Rt.Promise.await owner)

let unlock ?secret_key passphrase =
  ask
    (("action", "vault_unlock") :: ("passphrase", passphrase)
    :: Option.fold ~none:[] ~some:(fun k -> [("secretKey", k)]) secret_key)

let after_restart () =
  let passphrase = Fs.read_file passphrase_file
  and secret_key = Fs.read_file secret_key_file in
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      with_owner (fun () ->
          status "status";
          answer "unlock, the passphrase alone" (unlock passphrase);
          answer "unlock, with the secret key" (unlock ~secret_key passphrase);
          status "status"))

(* vault §6.1 against a keystore kept in files of ROOT, as a host's would
   survive the owner; [broken] refuses every write, [stuck] every delete, and reads fail until the
   file [up_marker] exists when [late]. *)
let keystore_dir = Filename.concat root "keystore"
let up_marker = Filename.concat root "keystore-up"

let file_keystore ?(stuck = false) ?(stuck_secret_key = false) ?(late = false)
    ~broken () : Keystore.t =
  let path name =
    Filename.concat keystore_dir
      (String.map (function '/' -> '#' | c -> c) name)
  in
  {
    name = "test keystore";
    put =
      (fun ~domain ~key_id ~key ->
        if broken then Fail.raise_ Denied "the test keystore refuses writes";
        Fs.mkdir_p keystore_dir;
        Fs.write_file_for_test (path domain) (key_id ^ key));
    get =
      (fun ~domain ->
        if late && not (Sys.file_exists up_marker) then
          Fail.raise_ Refused "the test keystore is not up yet";
        Option.map
          (fun s -> (String.sub s 0 16, String.sub s 16 (String.length s - 16)))
          (Fs.read_file_opt (path domain)));
    delete =
      (fun ~domain ->
        if
          stuck
          || (stuck_secret_key && String.ends_with ~suffix:"/secret-key" domain)
        then Fail.raise_ Refused "the test keystore keeps its entries";
        Fs.unlink_quiet (path domain));
  }

let entries () =
  if Sys.file_exists keystore_dir then
    String.concat " "
      (List.sort compare (Array.to_list (Sys.readdir keystore_dir)))
  else ""

let with_keystore ?stuck ?stuck_secret_key ?late ~broken f =
  Keystore.register (file_keystore ?stuck ?stuck_secret_key ?late ~broken ());
  let passphrase = Fs.read_file passphrase_file
  and secret_key = Fs.read_file secret_key_file in
  Owner.stop_on_signals ();
  Rt.run_sync (fun () -> with_owner (fun () -> f passphrase secret_key))

let keystore_phase = function
  | "ks-unlock" ->
      with_keystore ~broken:false (fun passphrase secret_key ->
          status "status";
          answer "unlock" (unlock ~secret_key passphrase);
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ()))
  | "ks-late" ->
      Atomic.set Tsync_owner.Vault.keystore_retry 1.;
      with_keystore ~late:true ~broken:false (fun _ _ ->
          status "status";
          Fs.write_file_for_test up_marker "";
          status "status, the keystore up, within the retry";
          Rt.sleep 1.5;
          status "status, the keystore up, after the retry";
          Sys.remove up_marker)
  | "ks-restart" ->
      with_keystore ~broken:false (fun _ _ ->
          status "status";
          answer "lock" (ask [("action", "vault_lock")]);
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ()))
  | "ks-after-lock" ->
      with_keystore ~broken:false (fun passphrase _ ->
          status "status";
          answer "unlock, the passphrase alone" (unlock passphrase);
          status "status";
          answer "lock and forget"
            (Ipc.call socket
               (`Assoc
                  [
                    ("domain", `String "docs");
                    ("action", `String "vault_lock");
                    ("forget", `Bool true);
                  ]));
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ()))
  | "ks-half" ->
      with_keystore ~stuck_secret_key:true ~broken:false
        (fun passphrase secret_key ->
          answer "unlock" (unlock ~secret_key passphrase);
          answer "lock and forget, one delete refused"
            (Ipc.call socket
               (`Assoc
                  [
                    ("domain", `String "docs");
                    ("action", `String "vault_lock");
                    ("forget", `Bool true);
                  ]));
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ()))
  | "ks-stuck" ->
      with_keystore ~stuck:true ~broken:false (fun passphrase secret_key ->
          answer "unlock" (unlock ~secret_key passphrase);
          let r = ask [("action", "vault_delete"); ("confirm", "docs")] in
          answer "delete" r;
          p "%-34s %s" "  keystore left"
            (Option.value ~default:"-" (field r "keystoreLeft"));
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ()))
  | _ ->
      with_keystore ~stuck:true ~broken:true (fun passphrase secret_key ->
          answer "unlock" (unlock ~secret_key passphrase);
          status "status";
          p "%-34s [%s]" "keystore entries" (entries ());
          answer "lock, K in memory alone" (ask [("action", "vault_lock")]);
          status "status")

let child phase =
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; phase; root |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] pid with
    | _, WEXITED 0 -> ()
    | _ -> p "the %s owner failed" phase

let passphrase = "correct horse battery staple"
let second = "a second passphrase, longer"

let first_owner () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let secret_key = ref "" in
      with_owner (fun () ->
          p "== before init";
          status "status";
          answer "unlock" (unlock passphrase);
          answer "passphrase"
            (ask [("action", "vault_passphrase"); ("passphrase", second)]);
          p "== init";
          answer "init, 15 characters"
            (ask [("action", "vault_init"); ("passphrase", String.make 15 'a')]);
          secret_key :=
            secret "init"
              (ask [("action", "vault_init"); ("passphrase", passphrase)]);
          status "status";
          answer "init again"
            (ask [("action", "vault_init"); ("passphrase", passphrase)]);
          p "== lock and unlock";
          answer "lock" (ask [("action", "vault_lock")]);
          status "status";
          answer "passphrase while locked"
            (ask [("action", "vault_passphrase"); ("passphrase", second)]);
          answer "unlock, wrong passphrase"
            (unlock "correct horse battery stapler");
          answer "unlock, 15 characters" (unlock (String.make 15 'a'));
          answer "unlock, the passphrase" (unlock ("  " ^ passphrase ^ " "));
          status "status";
          p "== appearance (§8.1)";
          let look label =
            match member (ask [("action", "vault_status")]) "appearance" with
              | Some a ->
                  (* The key id is drawn at init: print what its colour is, not which. *)
                  let color = Option.get (field a "color") in
                  let shown =
                    if member a "colorChosen" = Some (`Bool true) then color
                    else if List.mem color Tsync_vault.Appearance.palette then
                      "the key id's"
                    else "outside the palette: " ^ color
                  in
                  p "%-34s color=%s chosen=%b icon=%s" label shown
                    (member a "colorChosen" = Some (`Bool true))
                    (match field a "icon" with
                      | Some b ->
                          string_of_int (String.length (Base64.decode_exn b))
                          ^ " bytes"
                      | None -> "none")
              | None -> p "%-34s no appearance" label
          in
          (* The smallest header check_icon reads: the signature, then IHDR. *)
          let png side =
            let be n =
              String.init 4 (fun i -> Char.chr ((n lsr (8 * (3 - i))) land 255))
            in
            "\x89PNG\r\n\x1a\n" ^ be 13 ^ "IHDR" ^ be side ^ be side
            ^ String.make 9 '\000'
          in
          let set fields =
            Ipc.call socket
              (`Assoc
                 (("domain", `String "docs")
                 :: ("action", `String "vault_appearance")
                 :: fields))
          in
          look "default";
          answer "colour" (set [("color", `String "#0D9488")]);
          look "chosen";
          answer "a bad colour" (set [("color", `String "teal")]);
          answer "an icon"
            (set [("icon", `String (Base64.encode_string (png 64)))]);
          look "with an icon";
          answer "an oblong icon"
            (set
               [
                 ( "icon",
                   `String
                     (Base64.encode_string
                        (String.sub (png 64) 0 16
                        ^ "\000\000\000\064\000\000\000\032"
                        ^ String.make 9 '\000')) );
               ]);
          answer "a JPEG"
            (set
               [
                 ( "icon",
                   `String (Base64.encode_string "\xff\xd8\xff\xe0 not a png")
                 );
               ]);
          answer "back to the defaults"
            (set [("color", `Null); ("icon", `Null)]);
          look "default again";
          answer "colour, then lock" (set [("color", `String "#9333ea")]);
          answer "lock" (ask [("action", "vault_lock")]);
          answer "colour while locked" (set [("color", `String "#000000")]);
          look "locked, still shown";
          answer "unlock again" (unlock passphrase);
          p "== passphrase change";
          answer "passphrase"
            (ask [("action", "vault_passphrase"); ("passphrase", second)]);
          answer "lock" (ask [("action", "vault_lock")]);
          answer "unlock, the old one" (unlock passphrase);
          answer "unlock, the new one" (unlock second);
          status "status";
          p "== a new secret key";
          let old_key = !secret_key in
          secret_key :=
            secret "passphrase, new secret key"
              (Ipc.call socket
                 (`Assoc
                    [
                      ("domain", `String "docs");
                      ("action", `String "vault_passphrase");
                      ("passphrase", `String passphrase);
                      ("newSecretKey", `Bool true);
                    ]));
          p "%-34s %b" "a new one" (!secret_key <> old_key);
          p "== a machine not enrolled";
          answer "lock and forget"
            (Ipc.call socket
               (`Assoc
                  [
                    ("domain", `String "docs");
                    ("action", `String "vault_lock");
                    ("forget", `Bool true);
                  ]));
          status "status";
          answer "unlock, the passphrase alone" (unlock passphrase);
          answer "unlock, the old secret key"
            (unlock ~secret_key:old_key passphrase);
          answer "unlock, a malformed secret key"
            (unlock ~secret_key:"xyz" passphrase);
          answer "unlock, both" (unlock ~secret_key:!secret_key passphrase);
          status "status";
          p "== a domain that uses no extension";
          List.iter
            (fun action ->
              answer action
                (ask ~domain:"plain"
                   [
                     ("action", action);
                     ("passphrase", passphrase);
                     ("confirm", "plain");
                   ]))
            [
              "vault_status";
              "vault_init";
              "vault_lock";
              "vault_passphrase";
              "vault_delete";
            ];
          p "== delete";
          answer "delete, no confirmation" (ask [("action", "vault_delete")]);
          answer "delete, another name"
            (ask [("action", "vault_delete"); ("confirm", "plain")]);
          answer "delete"
            (ask [("action", "vault_delete"); ("confirm", "docs")]);
          status "status";
          answer "unlock" (unlock ~secret_key:!secret_key passphrase);
          secret_key :=
            secret "init again"
              (ask [("action", "vault_init"); ("passphrase", passphrase)]);
          answer "lock and forget"
            (Ipc.call socket
               (`Assoc
                  [
                    ("domain", `String "docs");
                    ("action", `String "vault_lock");
                    ("forget", `Bool true);
                  ])));
      Fs.write_file_for_test passphrase_file passphrase;
      Fs.write_file_for_test secret_key_file !secret_key)

let () =
  match phase with
    | Some "first" -> first_owner ()
    | Some "restart" -> after_restart ()
    | Some phase -> keystore_phase phase
    | None ->
        child "first";
        p "== after a restart";
        child "restart";
        p "== with a keystore: unlock";
        child "ks-unlock";
        p "== with a keystore that comes up after the owner";
        child "ks-late";
        p "== with a keystore: a restart, then lock";
        child "ks-restart";
        p "== with a keystore: a restart after the lock";
        child "ks-after-lock";
        p "== a keystore that refuses the write";
        child "ks-broken";
        p "== a keystore that keeps the secret key entry, then lock";
        child "ks-half";
        let secret_key = Fs.read_file secret_key_file in
        p "== a keystore that keeps its entries, then delete";
        child "ks-stuck";
        p "== the store";
        p "holds the keyring: %b" (store_holds {|{"keyId":"|});
        p "holds the passphrase: %b" (store_holds passphrase);
        p "holds the secret key spelled: %b" (store_holds secret_key);
        p "holds its bytes: %b"
          (store_holds
             (Option.get (Tsync_vault.Secret_key.of_string secret_key)));
        Fs.rm_rf root
