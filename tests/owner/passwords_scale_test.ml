(* passwords §11: a vault of 1000 logins answers within the deadlines a host
   imposes (Android gives a fill five seconds). Times go to stderr; the
   snapshot says only whether each is within its budget. *)

open Tsync_core
open Tsync_ipc
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-pws-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Tsync_config.Paths.owner_socket (Domain_name.v "pw")

let config_text =
  Printf.sprintf
    {|{"name":"test","domains":[
  {"name":"pw","symlinks":"keep","versioning":true,"extensions":["passwords"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
    root

let config = Tsync_config.Config.of_string config_text
let () = Unix.putenv "TSYNC_CONFIG_JSON" config_text
let ask fields = Ipc.call socket (`Assoc (("domain", `String "pw") :: fields))
let s v = `String v

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let count = 1000

let csv =
  "name,url,username,password,note\n"
  ^ String.concat ""
      (List.init count (fun i ->
           Printf.sprintf
             "Site %d,https://site%d.example/login,me%d@example.com,password \
              %06d,\n"
             i i i i))

(* The seconds [f] took, said on stderr; whether they are within [budget]. *)
let timed label ~budget f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "%s: %.3f s\n%!" label dt;
  p "%-44s %s"
    (Printf.sprintf "%s within %g s" label budget)
    (if dt <= budget then "yes" else "NO");
  r

let records r =
  match r with
    | `Assoc l -> (
        match List.assoc_opt "records" l with Some (`List rs) -> rs | _ -> [])
    | _ -> []

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      ignore
        (timed "init" ~budget:35. (fun () ->
             ask
               [
                 ("action", s "vault_init");
                 ("passphrase", s "correct horse battery staple");
               ]));
      (* ponytail: setup in batches, each within one call's deadline; an
         import's own speed is the sync engine's group commit, not timed here. *)
      let rows = List.tl (String.split_on_char '\n' csv) in
      let added = ref 0 in
      for b = 0 to (count / 100) - 1 do
        let chunk = List.filteri (fun i _ -> i / 100 = b) rows in
        let t0 = Unix.gettimeofday () in
        let r =
          Ipc.call ~timeout:600. socket
          @@ `Assoc
               [
                 ("domain", s "pw");
                 ("action", s "passwords_import");
                 ( "text",
                   s
                     ("name,url,username,password,note\n"
                    ^ String.concat "\n" chunk) );
               ]
        in
        (added :=
           !added
           +
             match r with
             | `Assoc l -> (
                 match List.assoc_opt "added" l with
                   | Some (`Int n) -> n
                   | _ -> 0)
             | _ -> 0);
        Printf.eprintf "setup batch %d: %.1f s\n%!" b
          (Unix.gettimeofday () -. t0)
      done;
      p "%-44s %d" "added" !added;
      (* ponytail: a fixed wait for the import's uploads, whose completions
         change the records' versions; wait on the owner's pending count if
         this ever flakes. *)
      Unix.sleepf 5.;
      let lookup i () =
        ask
          [
            ("action", s "passwords_list");
            ("site", s (Printf.sprintf "https://site%d.example" i));
          ]
      in
      let first = timed "first site lookup" ~budget:2. (lookup 1) in
      p "%-44s %d" "  its matches" (List.length (records first));
      (* Budgets that the reads before README §4.6 miss (3.8 s and 0.2 s on a
         laptop) on a slower machine too. *)
      timed "20 more site lookups" ~budget:3. (fun () ->
          for i = 2 to 21 do
            ignore (lookup i ())
          done);
      let id =
        match records first with
          | `Assoc r :: _ -> (
              match List.assoc_opt "id" r with
                | Some (`String id) -> id
                | _ -> "")
          | _ -> ""
      in
      ignore
        (timed "a passkey match" ~budget:0.25 (fun () ->
             ask
               [
                 ("action", s "passwords_passkey_match");
                 ("origin", s "https://site3.example");
                 ("rpId", s "site3.example");
               ]));
      (* README §4.6: an edit is read again; a lock drops what was opened. *)
      let title r =
        match records r with
          | `Assoc r :: _ -> (
              match List.assoc_opt "title" r with
                | Some (`String t) -> t
                | _ -> "")
          | _ -> ""
      in
      ignore
        (ask
           [
             ("action", s "passwords_edit"); ("id", s id); ("title", s "Renamed");
           ]);
      p "%-44s %s" "after an edit, the lookup's title" (title (lookup 1 ()));
      ignore (ask [("action", s "vault_lock")]);
      p "%-44s %s" "a lookup while locked"
        (match Ipc.field (lookup 1 ()) "code" with
          | Some c -> c
          | None -> "answered");
      ignore
        (ask
           [
             ("action", s "vault_unlock");
             ("passphrase", s "correct horse battery staple");
           ]);
      p "%-44s %s" "after the unlock" (title (lookup 1 ()));
      ignore (ask [("action", s "stop")]);
      p "owner exit status %d" (Rt.Promise.await owner));
  Fs.rm_rf root
