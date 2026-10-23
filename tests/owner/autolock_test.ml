(* vault §6.2 through a real owner: the idle and age limits, the watcher that
   locks with no verb asked, a host's screen report, and K kept out of the
   keystore. A policy's minute is shortened; every wait has a wide margin. *)

open Tsync_core
open Tsync_ipc
module Owner = Tsync_owner.Owner
module Keystore = Tsync_owner.Keystore

let p fmt = Printf.printf (fmt ^^ "\n%!")
let phase = if Array.length Sys.argv = 3 then Some Sys.argv.(1) else None

let root =
  match phase with
    | Some _ -> Sys.argv.(2)
    | None -> Printf.sprintf "/tmp/tsync-autolock-%d" (Unix.getpid ())

let () =
  if phase = None then Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Filename.concat root "data/tsync/test.sock"

let config =
  let domain name policy =
    Printf.sprintf
      {|{"name":"%s","symlinks":"keep","versioning":true,"extensions":["totp"],%s"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/%s"}]}|}
      name policy root name
  in
  Tsync_config.Config.of_string
    (Printf.sprintf {|{"name":"test","domains":[%s,%s,%s]}|}
       (domain "idle" {|"vaultLock":{"idleMinutes":1,"onScreenLock":true},|})
       (domain "aged" {|"vaultLock":{"maxHours":1},|})
       (domain "free" ""))

let ask domain fields =
  Ipc.call socket
    (`Assoc
       (("domain", `String domain)
       :: List.map (fun (k, v) -> (k, `String v)) fields))

let field = Ipc.field
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let answer label r =
  match field r "error" with
    | Some e -> p "%-40s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-40s ok" label

let status label domain =
  let r = ask domain [("action", "vault_status")] in
  p "%-40s %s%s%s%s" label
    (Option.get (field r "vault"))
    (match field r "cached" with Some c -> " cached=" ^ c | None -> "")
    (match field r "lockedBy" with Some b -> " lockedBy=" ^ b | None -> "")
    (match member r "autoLock" with
      | Some a -> " autoLock=" ^ Yojson.Safe.to_string a
      | None -> "")

let vault domain =
  Option.get (field (ask domain [("action", "vault_status")]) "vault")

let passphrase = "correct horse battery staple"
let secret_key_file = Filename.concat root "secret-key"

let unlock ?secret_key domain =
  ask domain
    (("action", "vault_unlock") :: ("passphrase", passphrase)
    :: Option.fold ~none:[] ~some:(fun k -> [("secretKey", k)]) secret_key)

(* A verb that needs K: setting the vault's colour. *)
let touch domain =
  ask domain [("action", "vault_appearance"); ("color", "#2563eb")]

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
  ignore (ask "idle" [("action", "stop")]);
  p "owner exit status %d" (Rt.Promise.await owner)

(* vault §6.1's three calls over files of ROOT, which outlive the owner. *)
let keystore_dir = Filename.concat root "keystore"

let file_keystore () : Keystore.t =
  let path name =
    Filename.concat keystore_dir
      (String.map (function '/' -> '#' | c -> c) name)
  in
  {
    name = "test keystore";
    put =
      (fun ~domain ~key_id ~key ->
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

(* Polls [vault], so a late lock costs time and never a wrong verdict. *)
let locked_within domain seconds =
  let deadline = Unix.gettimeofday () +. seconds in
  let rec go () =
    vault domain = "locked"
    || Unix.gettimeofday () < deadline
       &&
       (Rt.sleep 0.1;
        go ())
  in
  go ()

let init domain =
  Option.get
    (field
       (ask domain [("action", "vault_init"); ("passphrase", passphrase)])
       "secretKey")

let first () =
  Keystore.register (file_keystore ());
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      (* Before any unlock: a watcher keeps the tick it started with. *)
      Atomic.set Tsync_owner.Vault.minute 2.;
      with_owner (fun () ->
          Fs.write_file_for_test secret_key_file (init "idle");
          ignore (init "aged");
          ignore (init "free");
          p "== the keystore under a policy";
          status "idle" "idle";
          status "free" "free";
          p "%-40s [%s]" "keystore entries" (entries ());
          p "== idle, a minute of 2 s";
          answer "unlock" (unlock "idle");
          let used = ref true in
          for _ = 1 to 6 do
            Rt.sleep 0.5;
            used := !used && field (touch "idle") "error" = None
          done;
          p "%-40s %b" "used every 0.5 s for 3 s" !used;
          p "%-40s %b" "locked within 8 s of statuses alone"
            (locked_within "idle" 8.);
          status "idle" "idle";
          answer "a use" (touch "idle");
          p "== the screen";
          answer "unlock" (unlock "idle");
          answer "unlock free" (unlock "free");
          answer "screen report, idle"
            (ask "idle" [("action", "vault_lock"); ("reason", "screen")]);
          answer "screen report, free"
            (ask "free" [("action", "vault_lock"); ("reason", "screen")]);
          status "idle" "idle";
          status "free" "free";
          answer "unlock" (unlock "idle");
          status "idle, after the unlock" "idle";
          answer "lock" (ask "idle" [("action", "vault_lock")]);
          p "== age, a minute of 0.05 s: an hour of 3 s";
          Atomic.set Tsync_owner.Vault.minute 0.05;
          answer "unlock" (unlock "aged");
          let started = Unix.gettimeofday () in
          let rec use () =
            if field (touch "aged") "error" = None then (
              Rt.sleep 0.2;
              use ())
          in
          use ();
          let after = Unix.gettimeofday () -. started in
          p "%-40s %b" "locked while used, after 3 s or more" (after >= 3.);
          status "aged" "aged";
          answer "lock free" (ask "free" [("action", "vault_lock")]);
          Atomic.set Tsync_owner.Vault.minute 60.;
          answer "unlock" (unlock "idle");
          answer "unlock free" (unlock "free");
          p "%-40s [%s]" "keystore entries" (entries ())))

(* A restart: no K entry under a policy, so the vault is locked and still
   enrolled. *)
let restart () =
  Keystore.register (file_keystore ());
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      with_owner (fun () ->
          status "idle" "idle";
          status "free" "free";
          answer "unlock, the passphrase alone" (unlock "idle")))

let child phase =
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; phase; root |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] pid with
    | _, WEXITED 0 -> ()
    | _ -> p "the %s owner failed" phase

let () =
  match phase with
    | Some "first" -> first ()
    | Some "restart" -> restart ()
    | Some other -> failwith other
    | None ->
        child "first";
        p "== after a restart";
        child "restart";
        Fs.rm_rf root
