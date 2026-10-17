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
        p "%-32s %s%s%s slots=%s" label
          (Option.get (field r "vault"))
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
  match field r "passphrase" with
    | Some s ->
        p "%-32s passphrase %s, key id of %d hex" label (shape s)
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

let after_restart () =
  let passphrase = Fs.read_file passphrase_file in
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      with_owner (fun () ->
          status "status";
          answer "unlock"
            (ask [("action", "vault_unlock"); ("passphrase", passphrase)]);
          status "status"))

(* vault §6.1 against a keystore kept in files of ROOT, as a host's would
   survive the owner; [broken] refuses every write. *)
let keystore_dir = Filename.concat root "keystore"

let file_keystore ~broken : Keystore.t =
  let path domain = Filename.concat keystore_dir domain in
  {
    name = "test keystore";
    put =
      (fun ~domain ~key_id ~key ->
        if broken then Fail.raise_ Denied "the test keystore refuses writes";
        Fs.mkdir_p keystore_dir;
        Fs.write_file_for_test (path domain) (key_id ^ key));
    get =
      (fun ~domain ->
        Option.map
          (fun s -> (String.sub s 0 16, String.sub s 16 (String.length s - 16)))
          (Fs.read_file_opt (path domain)));
    delete = (fun ~domain -> Fs.unlink_quiet (path domain));
  }

let entries () =
  if Sys.file_exists keystore_dir then
    String.concat " "
      (List.sort compare (Array.to_list (Sys.readdir keystore_dir)))
  else ""

let with_keystore ~broken f =
  Keystore.register (file_keystore ~broken);
  let passphrase = Fs.read_file passphrase_file in
  Owner.stop_on_signals ();
  Rt.run_sync (fun () -> with_owner (fun () -> f passphrase))

let keystore_phase = function
  | "ks-unlock" ->
      with_keystore ~broken:false (fun passphrase ->
          status "status";
          answer "unlock"
            (ask [("action", "vault_unlock"); ("passphrase", passphrase)]);
          status "status";
          p "%-32s [%s]" "keystore entries" (entries ()))
  | "ks-restart" ->
      with_keystore ~broken:false (fun _ ->
          status "status";
          answer "lock" (ask [("action", "vault_lock")]);
          status "status";
          p "%-32s [%s]" "keystore entries" (entries ()))
  | "ks-after-lock" -> with_keystore ~broken:false (fun _ -> status "status")
  | _ ->
      with_keystore ~broken:true (fun passphrase ->
          answer "unlock"
            (ask [("action", "vault_unlock"); ("passphrase", passphrase)]);
          status "status";
          p "%-32s [%s]" "keystore entries" (entries ()))

let child phase =
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; phase; root |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] pid with
    | _, WEXITED 0 -> ()
    | _ -> p "the %s owner failed" phase

let first_owner () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let first = ref "" in
      with_owner (fun () ->
          p "== before init";
          status "status";
          answer "unlock"
            (ask
               [("action", "vault_unlock"); ("passphrase", String.make 26 '0')]);
          answer "passphrase" (ask [("action", "vault_passphrase")]);
          p "== init";
          first := secret "init" (ask [("action", "vault_init")]);
          status "status";
          answer "init again" (ask [("action", "vault_init")]);
          p "== lock and unlock";
          answer "lock" (ask [("action", "vault_lock")]);
          status "status";
          answer "passphrase while locked"
            (ask [("action", "vault_passphrase")]);
          answer "unlock, wrong passphrase"
            (ask
               [("action", "vault_unlock"); ("passphrase", String.make 26 '0')]);
          answer "unlock, 25 characters"
            (ask
               [("action", "vault_unlock"); ("passphrase", String.make 25 '0')]);
          answer "unlock, padding bits set"
            (ask
               [("action", "vault_unlock"); ("passphrase", String.make 26 'z')]);
          let typed =
            String.uppercase_ascii
              (String.concat " " (String.split_on_char '-' !first))
          in
          answer "unlock, upper case and spaces"
            (ask [("action", "vault_unlock"); ("passphrase", typed)]);
          status "status";
          p "== passphrase change";
          let second =
            secret "passphrase" (ask [("action", "vault_passphrase")])
          in
          p "%-32s %b" "a new one" (second <> !first);
          answer "lock" (ask [("action", "vault_lock")]);
          answer "unlock, the old one"
            (ask [("action", "vault_unlock"); ("passphrase", !first)]);
          answer "unlock, the new one"
            (ask [("action", "vault_unlock"); ("passphrase", second)]);
          status "status";
          first := second;
          p "== a domain that uses no extension";
          List.iter
            (fun action ->
              answer action (ask ~domain:"plain" [("action", action)]))
            ["vault_status"; "vault_init"; "vault_lock"; "vault_passphrase"]);
      Fs.write_file_for_test passphrase_file !first)

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
        p "== with a keystore: a restart, then lock";
        child "ks-restart";
        p "== with a keystore: a restart after the lock";
        child "ks-after-lock";
        p "== a keystore that refuses the write";
        child "ks-broken";
        let passphrase = Fs.read_file passphrase_file in
        Fs.unlink_quiet passphrase_file;
        p "== the store";
        p "holds the keyring: %b" (store_holds {|{"keyId":"|});
        p "holds the passphrase spelled: %b" (store_holds passphrase);
        p "holds its bytes: %b"
          (store_holds
             (Option.get (Tsync_vault.Passphrase.of_string passphrase)));
        Fs.rm_rf root
