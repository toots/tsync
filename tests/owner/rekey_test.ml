(* vault §6.3 and §7.2 through a real owner: two machines, told apart by the
   client uuid each phase writes before its owner starts, enrolling, being
   listed and announced, and a re-key shutting out the one that has not the
   new secret key.

   Each phase is a fresh owner with that machine's own keystore, kept in files
   of ROOT as a host's would outlive the owner. *)

open Tsync_core
open Tsync_ipc
module Owner = Tsync_owner.Owner
module Keystore = Tsync_owner.Keystore

let p fmt = Printf.printf (fmt ^^ "\n%!")
let phase = if Array.length Sys.argv = 3 then Some Sys.argv.(1) else None

let root =
  match phase with
    | Some _ -> Sys.argv.(2)
    | None -> Printf.sprintf "/tmp/tsync-rekey-%d" (Unix.getpid ())

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
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":["totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let uuid_a = String.make 32 'a'
let uuid_b = String.make 32 'b'
let passphrase = "correct horse battery staple"
let second = "a second passphrase, longer"
let file name = Filename.concat root name

let ask fields =
  Ipc.call socket
    (`Assoc
       (("domain", `String "docs")
       :: List.map (fun (k, v) -> (k, `String v)) fields))

let field = Ipc.field
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let answer label r =
  match field r "error" with
    | Some e -> p "%-36s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-36s ok" label

let status label =
  let r = ask [("action", "vault_status")] in
  let names k =
    match member r k with
      | Some (`List l) ->
          String.concat ", "
            (List.filter_map (function `String s -> Some s | _ -> None) l)
      | _ -> ""
  in
  p "%-36s %s%s%s%s" label
    (Option.get (field r "vault"))
    (match member r "enrolled" with
      | Some (`Bool true) -> " enrolled"
      | _ -> " not-enrolled")
    (match member r "secretKeyReplaced" with
      | Some (`Bool true) -> " secret-key-replaced"
      | _ -> "")
    (match names "newMachines" with "" -> "" | n -> " new: " ^ n)

(* 08: what the menu reads, from the domain's own status. *)
let domain_status label =
  let r = ask [("action", "status")] in
  p "%-36s newMachines [%s]" label
    (match member r "newMachines" with
      | Some (`List l) ->
          String.concat ", "
            (List.filter_map (function `String s -> Some s | _ -> None) l)
      | _ -> "")

(* The owner reads the list in the background at start: polls for it. *)
let announced_within seconds =
  let deadline = Unix.gettimeofday () +. seconds in
  let rec go () =
    match member (ask [("action", "status")]) "newMachines" with
      | Some (`List (_ :: _)) -> ()
      | _ when Unix.gettimeofday () < deadline ->
          Rt.sleep 0.1;
          go ()
      | _ -> ()
  in
  go ()

let machines ?name label =
  let r =
    ask
      (("action", "vault_machines")
      :: Option.fold ~none:[] ~some:(fun n -> [("name", n)]) name)
  in
  match member r "machines" with
    | Some (`List l) ->
        p "%-36s %s" label
          (String.concat "; "
             (List.map
                (fun m ->
                  Printf.sprintf "%s%s"
                    (Option.value ~default:"(does not open)" (field m "name"))
                    (match member m "this" with
                      | Some (`Bool true) -> " (this)"
                      | _ -> ""))
                l))
    | _ -> answer label r

(* vault §2.1: 26 characters in groups 5-5-5-5-6. *)
let shape s =
  String.concat "-"
    (List.map
       (fun g -> string_of_int (String.length g))
       (String.split_on_char '-' s))

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let file_keystore uuid : Keystore.t =
  let dir = file ("keystore-" ^ uuid) in
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

let as_machine uuid f =
  Keystore.register (file_keystore uuid);
  (* The host's own data directory: macOS keeps it outside XDG_DATA_HOME. *)
  let data = Tsync_config.Paths.data_dir () in
  Fs.mkdir_p data;
  Fs.write_file_for_test (Filename.concat data "client-uuid") (uuid ^ "\n");
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      f ();
      ignore (ask [("action", "stop")]);
      p "owner exit status %d" (Rt.Promise.await owner))

let unlock ?secret_key passphrase =
  ask
    (("action", "vault_unlock") :: ("passphrase", passphrase)
    :: Option.fold ~none:[] ~some:(fun k -> [("secretKey", k)]) secret_key)

let run = function
  | "a-init" ->
      as_machine uuid_a (fun () ->
          let r = ask [("action", "vault_init"); ("passphrase", passphrase)] in
          Fs.write_file_for_test (file "secret-key")
            (Option.get (field r "secretKey"));
          machines ~name:"machine A" "machines, named";
          status "status")
  | "b-enroll" ->
      as_machine uuid_b (fun () ->
          status "status";
          answer "unlock, the secret key given"
            (unlock ~secret_key:(Fs.read_file (file "secret-key")) passphrase);
          machines ~name:"machine B" "machines, named";
          status "status")
  | "a-rekey" ->
      as_machine uuid_a (fun () ->
          announced_within 10.;
          domain_status "domain status, before any vault verb";
          status "status";
          domain_status "domain status";
          machines "machines";
          status "status, after the list";
          domain_status "domain status, after the list";
          answer "rekey, wrong passphrase"
            (ask [("action", "vault_rekey"); ("passphrase", second)]);
          let r =
            ask
              [
                ("action", "vault_rekey");
                ("passphrase", passphrase);
                ("newPassphrase", second);
              ]
          in
          (match field r "secretKey" with
            | Some k ->
                p "%-36s secret key %s, a new one: %b, pending: %s" "rekey"
                  (shape k)
                  (k <> Fs.read_file (file "secret-key"))
                  (Option.value ~default:"none" (field r "pending"));
                Fs.write_file_for_test (file "new-secret-key") k
            | None -> answer "rekey" r);
          machines "machines";
          status "status")
  | "b-after" ->
      as_machine uuid_b (fun () ->
          answer "unlock, the old secret key"
            (unlock ~secret_key:(Fs.read_file (file "secret-key")) second);
          status "status";
          answer "unlock, the new secret key"
            (unlock ~secret_key:(Fs.read_file (file "new-secret-key")) second);
          status "status";
          machines ~name:"machine B" "machines, named again";
          answer "lock --forget"
            (Ipc.call socket
               (`Assoc
                  [
                    ("domain", `String "docs");
                    ("action", `String "vault_lock");
                    ("forget", `Bool true);
                  ])))
  | "a-last" ->
      as_machine uuid_a (fun () ->
          status "status";
          machines "machines")
  | other -> failwith other

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
    | Some phase -> run phase
    | None ->
        List.iter
          (fun phase ->
            p "== %s" phase;
            child phase)
          ["a-init"; "b-enroll"; "a-rekey"; "b-after"; "a-last"];
        Fs.rm_rf root
