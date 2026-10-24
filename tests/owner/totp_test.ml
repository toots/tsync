(* The totp verbs (spec extensions/totp §5, §6) through a serving owner, and
   their folds against a second client B that edits the same records. B holds
   the passphrase, as another machine of the user would. *)

open Tsync_core
open Tsync_ipc
open Tsync_store
open Tsync_sync
open Tsync_owner
module V = Tsync_vault

let p fmt = Printf.printf (fmt ^^ "\n%!")

(* Short: on macOS the owner's socket lives under the home directory. *)
let root = Printf.sprintf "/tmp/tsync-totp-%d" (Unix.getpid ())
let home = Filename.concat root "home"

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

(* Where the CLI looks for the owner of [docs]. *)
let socket = Tsync_config.Paths.owner_socket (Domain_name.v "docs")

let config_text =
  Printf.sprintf
    {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":["totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]},
  {"name":"plain","symlinks":"keep","versioning":true,"extensions":["passwords"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/plain"}]},
  {"name":"spare","symlinks":"keep","versioning":true,"extensions":["totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/spare"}]},
  {"name":"race","symlinks":"keep","versioning":true,"extensions":["totp"],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/race"}]}]}|}
    root root root root

let config = Tsync_config.Config.of_string config_text
let () = Unix.putenv "TSYNC_CONFIG_JSON" config_text

(* The CLI's [totp list] output, from the binary given as argv 1. *)
let cli_list args =
  let ic =
    Unix.open_process_args_in Sys.argv.(1)
      (Array.of_list
         ([Sys.argv.(1); "totp"; "list"; "--domain"; "docs"] @ args))
  in
  let lines = In_channel.input_lines ic in
  ignore (Unix.close_process_in ic);
  lines

(* A code: the first column, six digits grouped by three. *)
let shows_code line =
  String.length line > 7
  && String.for_all
       (function '0' .. '9' -> true | _ -> false)
       (String.sub line 0 3)
  && line.[3] = ' '

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

let client ?(domain = "docs") ?(store = "store") name : (module Engine.S) =
  let d = Domain_name.v domain in
  let data_dir = Filename.concat root (name ^ "/data") in
  let store = Local.create ~name:"main" (Filename.concat root store) in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      [{ name = "main"; role = Main; store }]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat root (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
    let projects_all = false
    let settings _ = (Tuning.default, symlinks)
  end in
  (module Engine.Make (C))

let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None
let field = Ipc.field

let ask ?(domain = "docs") fields =
  Ipc.call socket
    (`Assoc
       (("domain", `String domain)
       :: List.map (fun (k, v) -> (k, `String v)) fields))

let answer label r =
  match field r "error" with
    | Some e -> p "%-36s %s: %s" label (Option.get (field r "code")) e
    | None -> p "%-36s ok" label

(* Ids are random: shown as the order they were first seen. *)
let ids = Hashtbl.create 8

let show_id id =
  match Hashtbl.find_opt ids id with
    | Some n -> n
    | None ->
        let n = Printf.sprintf "<id%d>" (Hashtbl.length ids + 1) in
        Hashtbl.replace ids id n;
        n

let listing ?filter label =
  let r =
    ask
      (("action", "totp_list")
      :: Option.fold ~none:[] ~some:(fun f -> [("filter", f)]) filter)
  in
  match (member r "records", member r "corrupt") with
    | Some (`List rows), Some (`List corrupt) ->
        p "%s" label;
        List.iter
          (fun row ->
            let s k = Option.get (field row k) in
            let code = s "code" in
            p "  %s %S %S code of %d digits%s"
              (show_id (s "id"))
              (s "issuer") (s "account") (String.length code)
              (if String.for_all (fun c -> c >= '0' && c <= '9') code then ""
               else " NOT DIGITS"))
          rows;
        List.iter
          (function `String id -> p "  corrupt %s" (show_id id) | _ -> ())
          corrupt
    | _ -> answer label r

let added ?domain label uri =
  let r = ask ?domain [("action", "totp_add"); ("uri", uri)] in
  match field r "id" with
    | Some id ->
        p "%-36s %s" label (show_id id);
        id
    | None ->
        answer label r;
        ""

let read_file (module E : Engine.S) path =
  let h = E.open_read path in
  Fun.protect
    ~finally:(fun () -> E.close_read h)
    (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:(E.stat path).size))

let put (module E : Engine.S) path body =
  E.create path ~exclusive:false;
  E.truncate path 0;
  E.write path ~off:0 (Bigstring.of_string body);
  E.close path

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

let folder = ".tsync-ext/totp"

(* B, another machine: K from the keyring with both secrets. *)
let b_key (module B : Engine.S) ~secret_key passphrase =
  let keyring =
    Result.get_ok
      (V.Keyring.of_string (read_file (module B) ".tsync-ext/vault/keyring"))
  in
  ( keyring.key_id,
    Result.get_ok
      (V.Keyring.unlock keyring
         ~secret_key:(Option.get (V.Secret_key.of_string secret_key))
         passphrase) )

let b_edit (module B : Engine.S) (key_id, key) id f =
  let path = Names.join folder id in
  let r =
    Result.get_ok
      (V.Totp.of_string
         (Result.get_ok
            (V.Envelope.open_ ~key ~key_id ~extension:"totp"
               (read_file (module B) path))))
  in
  put
    (module B)
    path
    (V.Envelope.seal ~key ~key_id ~extension:"totp" (V.Totp.to_string (f r)))

(* The owner's sync until it owes nothing: what it changed is then in the store. *)
let rec settle_owner ?(domain = "docs") n =
  let r = ask ~domain [("action", "sync")] in
  match member r "pending" with
    | Some (`Int 0) -> ()
    | _ when n > 0 ->
        Rt.sleep 0.1;
        settle_owner ~domain (n - 1)
    | _ -> p "  the owner still owes uploads"

(* One edit on each side while the owner is paused, then the owner arrives. *)
let concurrently b ~owner ~on_b =
  let (module B : Engine.S) = b in
  ignore (B.resync ());
  answer "  pause" (ask [("action", "pause"); ("arg", "on")]);
  owner ();
  on_b ();
  B.drain ~grace:10. ();
  answer "  resume" (ask [("action", "pause"); ("arg", "off")]);
  settle_owner 100

let leaves (module B : Engine.S) =
  ignore (B.resync ());
  String.concat " "
    (List.sort compare
    @@ List.map
         (fun (e : B.entry) ->
           if String.length e.name > 32 then
             show_id (String.sub e.name 0 32)
             ^ String.sub e.name 32 (String.length e.name - 32)
           else show_id e.name)
         (B.list_children folder))

(* format-merge §2: copies settle in the background after an arrival; wait for
   them rather than for a duration. *)
let settled_leaves ?(path = folder) b =
  let (module B : Engine.S) = b in
  let names () =
    ignore (B.resync ());
    List.map (fun (e : B.entry) -> e.name) (B.list_children path)
  in
  let deadline = Unix.gettimeofday () +. 20. in
  let rec wait () =
    settle_owner 100;
    if
      List.exists (fun n -> Tsync_vault.Fold.copied_from n <> None) (names ())
      && Unix.gettimeofday () < deadline
    then (
      Rt.sleep 0.1;
      wait ())
  in
  wait ();
  if path = folder then leaves b else String.concat " " (names ())

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      p "== before init";
      answer "list" (ask [("action", "totp_list")]);
      let passphrase = "correct horse battery staple" in
      let secret_key =
        Option.get
          (field
             (ask [("action", "vault_init"); ("passphrase", passphrase)])
             "secretKey")
      in
      answer "lock" (ask [("action", "vault_lock")]);
      p "== locked";
      List.iter
        (fun (label, fields) -> answer label (ask fields))
        [
          ( "add",
            [
              ("action", "totp_add");
              ("uri", "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP");
            ] );
          ("list", [("action", "totp_list")]);
          ("code", [("action", "totp_code"); ("id", String.make 32 '0')]);
          ( "rename",
            [
              ("action", "totp_rename");
              ("id", String.make 32 '0');
              ("issuer", "x");
            ] );
          ("remove", [("action", "totp_remove"); ("id", String.make 32 '0')]);
          ("export", [("action", "totp_export"); ("passphrase", passphrase)]);
        ];
      answer "unlock"
        (ask [("action", "vault_unlock"); ("passphrase", passphrase)]);
      p "== add and list";
      let acme =
        added "add the §6 URI"
          "otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co"
      in
      List.iter
        (fun (label, uri) -> ignore (added label uri))
        [
          ("add hotp", "otpauth://hotp/a?secret=JBSWY3DPEHPK3PXP&counter=1");
          ("add 9 digits", "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&digits=9");
          ( "add an unknown algorithm",
            "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&algorithm=MD5" );
          ("add an empty secret", "otpauth://totp/a?secret=");
        ];
      let bob =
        added "add a lower-case padded secret"
          "otpauth://totp/Other:bob?secret=gezdgnbvgy3tqojq%3D%3D%3D"
      in
      answer "add a bare secret"
        (ask
           [
             ("action", "totp_add");
             ("secret", "mfrg gzdf mztw q2lk");
             ("issuer", "Text");
             ("account", "typed");
           ]);
      answer "add a secret with no labels"
        (ask [("action", "totp_add"); ("secret", "MFRGGZDFMZTWQ2LK")]);
      answer "add a secret and a uri"
        (ask
           [
             ("action", "totp_add");
             ("secret", "MFRGGZDFMZTWQ2LK");
             ("issuer", "Text");
             ("uri", "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP");
           ]);
      listing "list";
      (* §5: the CLI's list prints codes only when asked. *)
      (let plain = cli_list [] and shown = cli_list ["--show-codes"] in
       p "%-40s %d rows, %b" "cli list: no code" (List.length plain)
         (plain <> [] && not (List.exists shows_code plain));
       p "%-40s %d rows, %b" "cli list --show-codes" (List.length shown)
         (shown <> [] && List.for_all shows_code shown));
      listing ~filter:"acme" "list acme";
      (let seed =
         Result.get_ok
           (V.Totp.of_uri ~now:0 "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP")
       in
       let before = Int64.of_float (Unix.time ()) in
       let r = ask [("action", "totp_code"); ("id", acme)] in
       let after = Int64.of_float (Unix.time ()) in
       match field r "code" with
         | Some code ->
             p "%-36s matches the seed: %b, carries no seed: %b" "code"
               (code = V.Totp.code_at seed ~unix_time:before
               || code = V.Totp.code_at seed ~unix_time:after)
               (not
                  (Text.contains (Yojson.Safe.to_string r) "JBSWY3DPEHPK3PXP"))
         | None -> answer "code" r);
      answer "code of a malformed id"
        (ask [("action", "totp_code"); ("id", "xyz")]);
      answer "code of an absent id"
        (ask [("action", "totp_code"); ("id", String.make 32 '0')]);
      answer "rename"
        (ask [("action", "totp_rename"); ("id", acme); ("issuer", " ACME Inc ")]);
      answer "rename to nothing"
        (ask
           [
             ("action", "totp_rename");
             ("id", acme);
             ("issuer", " ");
             ("account", "");
           ]);
      answer "rename a malformed id"
        (ask [("action", "totp_rename"); ("id", "xyz"); ("issuer", "x")]);
      answer "remove an absent id"
        (ask [("action", "totp_remove"); ("id", String.make 32 '0')]);
      listing "list";
      answer "export without a passphrase" (ask [("action", "totp_export")]);
      answer "export, a wrong passphrase"
        (ask [("action", "totp_export"); ("passphrase", String.make 26 '0')]);
      (* A failed export prints its error, which the comparisons below would hide. *)
      let export ?(domain = "docs") label passphrase =
        let r =
          ask ~domain [("action", "totp_export"); ("passphrase", passphrase)]
        in
        match member r "uris" with
          | Some (`List uris) ->
              List.filter_map (function `String u -> Some u | _ -> None) uris
          | _ ->
              answer label r;
              []
      in
      p "export";
      List.iter (p "  %s") (export "export" passphrase);
      p "== import";
      let imported ?(domain = "docs") label text =
        let r = ask ~domain [("action", "totp_import"); ("text", text)] in
        match member r "refused" with
          | Some (`List refused) ->
              p "%-36s added %d, already %d%s" label
                (Option.value ~default:0
                   (Option.bind (member r "added") (function
                     | `Int n -> Some n
                     | _ -> None)))
                (Option.value ~default:0
                   (Option.bind (member r "already") (function
                     | `Int n -> Some n
                     | _ -> None)))
                (String.concat ""
                   (List.map (fun j -> " " ^ Yojson.Safe.to_string j) refused))
          | _ -> answer label r
      in
      let text =
        "  \
         otpauth://totp/Mail:me@example.org?secret=MFRGGZDFMZTWQ2LK&issuer=Mail \
         \n\n\
         otpauth://hotp/Counter:me?secret=MFRGGZDFMZTWQ2LK&counter=4\n\
         otpauth://totp/Mail:me@example.org?secret=MFRGGZDFMZTWQ2LK&issuer=Mail\n"
      in
      imported "import" text;
      imported "the same again" text;
      imported "separators"
        "otpauth://totp/Foo,%20Inc:a?secret=MFRGGZDFMZTWQ2LK, \
         otpauth://totp/B:b?secret=MFRGGZDFMZTWQ2LK;otpauth://hotp/C:c?secret=MFRGGZDFMZTWQ2LK\n\
         otpauth://totp/Raw, Inc:r?secret=MFRGGZDFMZTWQ2LK";
      listing "list";
      let exported = String.concat "\n" (export "export docs" passphrase) in
      let spare = "the spare vault's passphrase" in
      ignore
        (ask ~domain:"spare" [("action", "vault_init"); ("passphrase", spare)]);
      answer "export spare with docs' passphrase"
        (ask ~domain:"spare"
           [("action", "totp_export"); ("passphrase", passphrase)]);
      imported ~domain:"spare" "an export into an empty domain" exported;
      let again =
        String.concat "\n" (export ~domain:"spare" "export spare" spare)
      in
      p "%-36s %b" "  the same records" (again = exported);
      (* What differs, by label, should it ever. *)
      if again <> exported then (
        let labels text =
          List.map
            (fun u -> List.hd (String.split_on_char '?' u))
            (String.split_on_char '\n' text)
        in
        let only a b = List.filter (fun x -> not (List.mem x b)) a in
        List.iter (p "    only in docs: %s")
          (only (labels exported) (labels again));
        List.iter
          (p "    only in spare: %s")
          (only (labels again) (labels exported));
        if labels exported = labels again then
          p "    the same labels, another URI");
      answer "list on a domain without totp"
        (ask ~domain:"plain" [("action", "totp_list")]);
      Rt.sleep 0.5;
      ignore (ask [("action", "sync")]);
      p "== the store";
      p "holds the keyring: %b" (store_holds {|{"keyId":"|});
      p "holds a seed: %b"
        (store_holds "JBSWY3DPEHPK3PXP" || store_holds "GEZDGNBVGY3TQOJQ");
      p "holds a label: %b"
        (store_holds "john@example.com" || store_holds "ACME");
      let b = client "B" in
      let (module B) = b in
      B.start ~background:false ();
      ignore (B.resync ());
      let key = b_key b ~secret_key passphrase in
      p "== both rename one record";
      concurrently b
        ~owner:(fun () ->
          answer "  owner renames"
            (ask
               [
                 ("action", "totp_rename");
                 ("id", acme);
                 ("account", "owner@example.com");
               ]))
        ~on_b:(fun () ->
          b_edit b key acme (fun r ->
              { r with account = "b@example.com"; modified = r.modified + 3600 }));
      p "  after the arrival: %s" (settled_leaves b);
      listing "  list";
      settle_owner 100;
      p "  after: %s" (leaves b);
      p "== a copy arriving is settled with no verb asked (format-merge §2)";
      concurrently b
        ~owner:(fun () ->
          answer "  owner renames"
            (ask
               [("action", "totp_rename"); ("id", acme); ("issuer", "ACME Co")]))
        ~on_b:(fun () ->
          b_edit b key acme (fun r ->
              { r with issuer = "ACME B"; modified = r.modified + 7200 }));
      p "  after the arrival alone: %s" (settled_leaves b);
      p "== a seed changed in place on B";
      concurrently b
        ~owner:(fun () ->
          answer "  owner renames"
            (ask
               [("action", "totp_rename"); ("id", bob); ("issuer", "Other Inc")]))
        ~on_b:(fun () ->
          b_edit b key bob (fun r -> { r with secret = "JBSWY3DPEHPK3PXP" }));
      p "  after the arrival: %s" (settled_leaves b);
      listing "  list";
      settle_owner 100;
      p "  after: %s" (leaves b);
      listing "  list again, nothing to fold";
      settle_owner 100;
      p "  after: %s" (leaves b);
      p "== a record whose plaintext is corrupt";
      let bad = String.make 32 'c' in
      put b (Names.join folder bad)
        (V.Envelope.seal ~key:(snd key) ~key_id:(fst key) ~extension:"totp"
           "{not json");
      B.drain ~grace:10. ();
      settle_owner 100;
      listing "  list";
      settle_owner 100;
      p "  after: %s" (leaves b);
      (match
         member
           (ask [("action", "totp_export"); ("passphrase", passphrase)])
           "corrupt"
       with
        | Some (`List ids) ->
            p "  export names it: %b" (List.mem (`String bad) ids)
        | _ -> p "  export names nothing");
      answer "  remove it" (ask [("action", "totp_remove"); ("id", bad)]);
      listing "  list";
      p "== both change the keyring";
      concurrently b
        ~owner:(fun () ->
          answer "  owner changes the passphrase"
            (ask
               [
                 ("action", "vault_passphrase");
                 ("passphrase", "a second passphrase, longer");
               ]))
        ~on_b:(fun () ->
          let path = ".tsync-ext/vault/keyring" in
          let k = Result.get_ok (V.Keyring.of_string (read_file b path)) in
          let later =
            V.Keyring.Unknown
              {
                id = "5555555555555555";
                json =
                  `Assoc
                    [
                      ("id", `String "5555555555555555");
                      ("kind", `String "device");
                    ];
              }
          in
          put b path (V.Keyring.to_string { k with slots = later :: k.slots }));
      p "  after the arrival: %s" (settled_leaves ~path:".tsync-ext/vault" b);
      let st = ask [("action", "vault_status")] in
      p "  status %s slots=%s copies=%s"
        (Option.get (field st "vault"))
        (Yojson.Safe.to_string (Option.get (member st "slots")))
        (Yojson.Safe.to_string (Option.get (member st "copies")));
      settle_owner 100;
      p "  after: %s"
        (ignore (B.resync ());
         String.concat " "
           (List.map
              (fun (e : B.entry) -> e.name)
              (B.list_children ".tsync-ext/vault")));
      B.drain ~grace:10. ();
      p "== two inits race; the owner's loses";
      let race = client ~domain:"race" ~store:"race" "R" in
      let (module R) = race in
      R.start ~background:false ();
      let ask_race fields = ask ~domain:"race" fields in
      ignore (ask_race [("action", "vault_init"); ("passphrase", passphrase)]);
      ignore
        (added ~domain:"race" "  the owner adds under its K"
           "otpauth://totp/Race:a?secret=JBSWY3DPEHPK3PXP");
      settle_owner ~domain:"race" 100;
      (* What the race leaves: B's keyring at keyring, the owner's beside it. *)
      ignore (R.resync ());
      let path = ".tsync-ext/vault/keyring" in
      put race ".tsync-ext/vault/keyring (conflicted copy from test)"
        (read_file race path);
      let won = "the winning init's passphrase" in
      let won_secret_key = V.Secret_key.generate () in
      let _, keyring = V.Keyring.create ~now:0 ~secret_key:won_secret_key won in
      put race path (V.Keyring.to_string keyring);
      R.drain ~grace:10. ();
      settle_owner ~domain:"race" 100;
      let status label =
        let st = ask_race [("action", "vault_status")] in
        p "  %-34s %s copies=%d" label
          (Option.get (field st "vault"))
          (match member st "copies" with
            | Some (`List l) -> List.length l
            | _ -> -1)
      in
      status "status";
      answer "  list" (ask_race [("action", "totp_list")]);
      answer "  lock, the losing K held" (ask_race [("action", "vault_lock")]);
      answer "  unlock with the winner's passphrase"
        (ask_race
           [
             ("action", "vault_unlock");
             ("passphrase", won);
             ("secretKey", V.Secret_key.to_string won_secret_key);
           ]);
      (match member (ask_race [("action", "totp_list")]) "records" with
        | Some (`List rows) ->
            List.iter
              (fun row ->
                p "  list: %S %S"
                  (Option.get (field row "issuer"))
                  (Option.get (field row "account")))
              rows
        | _ -> p "  list failed");
      status "status";
      settle_owner ~domain:"race" 100;
      ignore (R.resync ());
      p "  the vault folder: %s"
        (String.concat " "
           (List.map
              (fun (e : R.entry) -> e.name)
              (R.list_children ".tsync-ext/vault")));
      R.drain ~grace:10. ();
      ignore (ask [("action", "stop")]);
      p "owner exit status %d" (Rt.Promise.await owner));
  Fs.rm_rf root
