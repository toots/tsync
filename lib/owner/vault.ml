open Tsync_core
open Tsync_sync
module Keyring = Tsync_vault.Keyring
module Passphrase = Tsync_vault.Passphrase
module Secret_key = Tsync_vault.Secret_key

let ext = Names.extension_root
let folder = Names.join ext "vault"
let keyring_path = Names.join folder "keyring"

(* vault §6: K under its key id and the secret key under its id, in the owner's
   memory and, where the host has one, its keystore (§6.1). *)
type t = {
  key : (string * string) option Atomic.t;
  secret_key : (string * string) option Atomic.t;
  cached : [ `Keystore | `Memory ] Atomic.t;
  restored : bool Atomic.t;  (** the keystore was read for this owner *)
  keystore_error : string option Atomic.t;
}

let create () =
  {
    key = Atomic.make None;
    secret_key = Atomic.make None;
    cached = Atomic.make `Memory;
    restored = Atomic.make false;
    keystore_error = Atomic.make None;
  }

(* §6.1: two entries per domain, named apart; no domain name holds a [/]. *)
let key_entry (domain : Tsync_domain.Domain.t) =
  Domain_name.to_string domain.name

let secret_key_entry domain = key_entry domain ^ "/secret-key"

(* §6.1 owner start: read once, before the first use of either secret. *)
let restore ~domain t =
  if not (Atomic.exchange t.restored true) then
    Option.iter
      (fun (ks : Keystore.t) ->
        match
          ( ks.get ~domain:(key_entry domain),
            ks.get ~domain:(secret_key_entry domain) )
        with
          | key, secret_key ->
              (* §6: a read never replaces a K the owner already holds. *)
              Option.iter
                (fun entry ->
                  if Atomic.compare_and_set t.key None (Some entry) then
                    Atomic.set t.cached `Keystore)
                key;
              Option.iter
                (fun entry ->
                  ignore (Atomic.compare_and_set t.secret_key None (Some entry)))
                secret_key
          | exception Fail.E f -> Atomic.set t.keystore_error (Some f.reason))
      (Keystore.registered ())

(* §6.1 unlock: a keystore that refuses leaves both in memory. *)
let store ~domain t ~key:(key_id, key) ~secret_key =
  Atomic.set t.key (Some (key_id, key));
  Atomic.set t.secret_key (Some (Secret_key.id secret_key, secret_key));
  Atomic.set t.cached `Memory;
  Option.iter
    (fun (ks : Keystore.t) ->
      match
        ks.put ~domain:(key_entry domain) ~key_id ~key;
        ks.put ~domain:(secret_key_entry domain)
          ~key_id:(Secret_key.id secret_key) ~key:secret_key
      with
        | () ->
            Atomic.set t.cached `Keystore;
            Atomic.set t.keystore_error None
        | exception Fail.E f ->
            Atomic.set t.keystore_error (Some f.reason);
            Log.warn "vault: %s keeps the keys in memory: %s" ks.name f.reason)
    (Keystore.registered ())

(* extensions README §3, 05 §2.1 rule 5: the configured list, else the one the
   main states, names this release does not know dropped. *)
let extensions ~(domain : Tsync_domain.Domain.t) ~engine =
  let (module E : Engine.S) = engine in
  Tsync_config.Config.extensions_in_force domain.domain (E.stated_settings ())

(* extensions README §3: a client that uses no extension of the domain runs
   none of the vault. *)
let check_uses ~(domain : Tsync_domain.Domain.t) ~engine =
  if extensions ~domain ~engine = [] then
    Fail.invalid "%s uses no extension: add one to its extensions in the config"
      (Domain_name.to_string domain.name)

let read_file (module E : Engine.S) path =
  let h = E.open_read path in
  Fun.protect
    ~finally:(fun () -> E.close_read h)
    (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:(E.stat path).size))

(* extensions README §4.1: on a lazy tree the folders the vault reads are
   pulled first, and a failed pull fails the verb. *)
let pull (module E : Engine.S) =
  List.iter
    (fun dir -> if E.kind dir = `Dir then ignore (E.pull dir))
    [""; ext; folder]

(* vault §3 step 2: init first brings the local tree to the main's. *)
let refresh engine ~lazy_tree =
  let (module E : Engine.S) = engine in
  if lazy_tree then pull engine else ignore (E.resync ())

let read_current engine ~lazy_tree = if lazy_tree then pull engine

(* §4.3: every extension's folder, whether this client uses it or not. *)
let extension_folders engine ~lazy_tree =
  let (module E : Engine.S) = engine in
  if E.kind ext <> `Dir then []
  else
    List.filter_map
      (fun (e : E.entry) ->
        if (not e.is_dir) || Names.join ext e.name = folder then None
        else (
          let dir = Names.join ext e.name in
          if lazy_tree then ignore (E.pull dir);
          Some (e.name, dir)))
      (E.list_children ext)

(* The files of an extension folder, read whole. *)
let files engine dir : Tsync_vault.Fold.file list =
  let (module E : Engine.S) = engine in
  if E.kind dir <> `Dir then []
  else
    List.filter_map
      (fun (e : E.entry) ->
        if e.is_dir then None
        else (
          let path = Names.join dir e.name in
          Some { Tsync_vault.Fold.name = e.name; body = read_file engine path }))
      (E.list_children dir)

let write_file (module E : Engine.S) ~exclusive path body =
  E.create path ~exclusive;
  E.truncate path 0;
  E.write path ~off:0 (Bigstring.of_string body);
  E.close path

(* README §4.2: a fold that cannot be applied now is left for the next. Its
   actions run in order and stop at the first failure, so a copy is never
   removed after what should have absorbed it failed to be written. *)
let apply engine dir actions =
  let (module E : Engine.S) = engine in
  try
    List.iter
      (function
        | Tsync_vault.Fold.Move { src; dst } ->
            E.rename ~src:(Names.join dir src) ~dst:(Names.join dir dst)
              ~exclusive:false
        | Remove name -> E.delete (Names.join dir name)
        | Write { name; body } ->
            write_file engine ~exclusive:false (Names.join dir name) body)
      actions
  with Fail.E f -> Log.warn "vault: a fold in %s is left: %s" dir f.reason

type found = {
  keyring : [ `Absent | `Corrupt of string | `Ok of Keyring.t ];
  copies : string list;  (** the conflicted copies beside it *)
}

(* §8: the keyring's fold runs only where this client may write the domain. *)
let read ~(domain : Tsync_domain.Domain.t) engine =
  let (module E : Engine.S) = engine in
  let actions, others =
    Tsync_vault.Fold.keyring ~name:"keyring" (files engine folder)
  in
  if not domain.domain.read_only then apply engine folder actions;
  let keyring =
    match E.kind keyring_path with
      | `Absent | `Dir -> `Absent
      | `File -> (
          match Keyring.of_string (read_file engine keyring_path) with
            | Ok k -> `Ok k
            | Error reason -> `Corrupt reason)
  in
  { keyring; copies = List.map (Names.join folder) others }

let write engine ~exclusive keyring =
  let (module E : Engine.S) = engine in
  List.iter (fun dir -> E.mkdir dir ~exclusive:false) [ext; folder];
  write_file engine ~exclusive keyring_path (Keyring.to_string keyring)

let now () = int_of_float (Unix.time ())

let secret ~key_id secret_key : Protocol.secret =
  { secret_key = Secret_key.to_string secret_key; key_id }

let chosen typed =
  match Passphrase.of_typed typed with
    | Ok passphrase -> passphrase
    | Error reason -> Fail.invalid "%s" reason

let init ~domain ~engine ~lazy_tree t typed =
  check_uses ~domain ~engine;
  let passphrase = chosen typed in
  refresh engine ~lazy_tree;
  (match (read ~domain engine).keyring with
    | `Absent -> ()
    | `Ok _ | `Corrupt _ ->
        Fail.raise_ Exists "%s already has a vault: unlock it"
          (Domain_name.to_string domain.name));
  let secret_key = Secret_key.generate () in
  let key, keyring = Keyring.create ~now:(now ()) ~secret_key passphrase in
  write engine ~exclusive:true keyring;
  store ~domain t ~key:(keyring.key_id, key) ~secret_key;
  secret ~key_id:keyring.key_id secret_key

(* §7.1: a machine that finds the vault gone forgets the K it held. *)
let gone ~domain t =
  if Atomic.exchange t.key None <> None then
    Option.iter
      (fun (ks : Keystore.t) ->
        try ks.delete ~domain:(key_entry domain)
        with Fail.E f ->
          Log.warn "vault: %s keeps the key of a deleted vault: %s" ks.name
            f.reason)
      (Keystore.registered ())

let current ~domain engine ~lazy_tree t =
  read_current engine ~lazy_tree;
  match (read ~domain engine).keyring with
    | `Ok k -> k
    | `Absent ->
        gone ~domain t;
        Fail.absent "this domain has no vault: run tsync vault init"
    | `Corrupt reason -> Fail.corrupt "the keyring is unreadable: %s" reason

(* vault §6: the secret key given, else the one this machine is enrolled
   with. *)
let secret_key_of ?given t =
  match given with
    | Some typed -> (
        match Secret_key.of_string typed with
          | Some key -> key
          | None ->
              Fail.invalid "a secret key is 26 characters in groups 5-5-5-5-6")
    | None -> (
        match Atomic.get t.secret_key with
          | Some (_, key) -> key
          | None -> Fail.invalid "this machine needs the vault's secret key")

(* vault §6: K from the slots of that secret key. *)
let unwrap ?secret_key ~domain ~engine ~lazy_tree t typed =
  let keyring = current ~domain engine ~lazy_tree t in
  let secret_key = secret_key_of ?given:secret_key t in
  let passphrase = chosen typed in
  match Keyring.unlock keyring ~secret_key passphrase with
    | Ok key -> (keyring, key, secret_key)
    | Error `Wrong_secret_key ->
        Fail.raise_ Denied "wrong secret key: it is not this vault's"
    | Error (`Unusable ids) ->
        Fail.invalid
          "this machine's slots (%s) are outside this release's limits; unlock \
           on a machine that can, and change the passphrase there"
          (String.concat ", " ids)
    | Error `Wrong_passphrase -> Fail.raise_ Denied "wrong passphrase"

(* vault §4.3: a machine holding a losing init's K moves every record sealed
   under it to the domain's K, then drops the keyring copies naming it. *)
let rekey ~engine ~lazy_tree ~from:(old_id, old_key) ~into:(key_id, key) =
  let module Envelope = Tsync_vault.Envelope in
  List.iter
    (fun (extension, dir) ->
      List.iter
        (fun (f : Tsync_vault.Fold.file) ->
          match
            Envelope.open_ ~key:old_key ~key_id:old_id ~extension f.body
          with
            | Ok plaintext ->
                write_file engine ~exclusive:false (Names.join dir f.name)
                  (Envelope.seal ~key ~key_id ~extension plaintext)
            | Error _ -> ())
        (files engine dir))
    (extension_folders engine ~lazy_tree);
  let copies =
    List.filter_map
      (fun (f : Tsync_vault.Fold.file) ->
        match Keyring.of_string f.body with
          | Ok k when f.name <> "keyring" && k.key_id = old_id ->
              Some (Tsync_vault.Fold.Remove f.name)
          | _ -> None)
      (files engine folder)
  in
  apply engine folder copies

let unlock ?secret_key ~domain ~engine ~lazy_tree t typed =
  check_uses ~domain ~engine;
  restore ~domain t;
  let keyring, key, secret_key =
    unwrap ?secret_key ~domain ~engine ~lazy_tree t typed
  in
  (* §4.3: the old K is dropped only once its records are re-encrypted; a
     failure here leaves it held for the next unlock. *)
  (match Atomic.get t.key with
    | Some ((old_id, _) as old) when old_id <> keyring.key_id ->
        rekey ~engine ~lazy_tree ~from:old ~into:(keyring.key_id, key)
    | _ -> ());
  store ~domain t ~key:(keyring.key_id, key) ~secret_key

(* totp §5: the user's own request, told apart by the passphrase. *)
let confirm ~domain ~engine ~lazy_tree t typed =
  check_uses ~domain ~engine;
  restore ~domain t;
  ignore (unwrap ~domain ~engine ~lazy_tree t typed)

(* §6.1: a lock whose delete failed did not happen. *)
let forget ~domain ~secret_key t =
  let deleted entry =
    match Keystore.registered () with
      | None -> None
      | Some ks -> (
          match ks.delete ~domain:entry with
            | () -> None
            | exception Fail.E f -> Some (ks.name, f.reason))
  in
  let key_failure = deleted (key_entry domain) in
  if key_failure = None then Atomic.set t.key None;
  let secret_key_failure =
    if secret_key then deleted (secret_key_entry domain) else None
  in
  if secret_key && secret_key_failure = None then Atomic.set t.secret_key None;
  match (key_failure, secret_key_failure) with
    | Some (name, reason), _ | None, Some (name, reason) ->
        Fail.raise_ Unexplained "%s could not forget the key: %s" name reason
    | None, None -> ()

let lock ?(forget_secret_key = false) ~domain ~engine ~lazy_tree:_ t =
  check_uses ~domain ~engine;
  restore ~domain t;
  forget ~domain ~secret_key:forget_secret_key t

(* The K held for the keyring's key id: one for another id is not adopted
   (vault §6). *)
let key t keyring =
  match Atomic.get t.key with
    | Some (id, key) when id = keyring.Keyring.key_id -> Some key
    | _ -> None

let held ~domain ~engine ~lazy_tree t =
  check_uses ~domain ~engine;
  restore ~domain t;
  let keyring = current ~domain engine ~lazy_tree t in
  match key t keyring with
    | Some k -> (keyring, k)
    | None -> Fail.raise_ Locked "the vault is locked: run tsync vault unlock"

(* vault §7: a new slot replaces every [secret-key] slot; others are kept. *)
let passphrase ?(new_secret_key = false) ~domain ~engine ~lazy_tree t typed =
  let keyring, key = held ~domain ~engine ~lazy_tree t in
  let passphrase = chosen typed in
  let enrolled =
    match Atomic.get t.secret_key with
      | Some (id, sk) when Keyring.enrolls keyring ~secret_key_id:id -> sk
      | _ ->
          Fail.raise_ Locked
            "this machine is not enrolled: unlock it with the secret key"
  in
  let secret_key =
    if new_secret_key then Secret_key.generate () else enrolled
  in
  let slot =
    Keyring.slot ~now:(now ()) ~key_id:keyring.key_id ~key ~secret_key
      passphrase
  in
  let others =
    List.filter
      (function Keyring.Secret_key _ -> false | Unknown _ -> true)
      keyring.slots
  in
  write engine ~exclusive:false { keyring with slots = slot :: others };
  if new_secret_key then (
    store ~domain t ~key:(keyring.key_id, key) ~secret_key;
    Some (secret ~key_id:keyring.key_id secret_key))
  else None

(* vault §7.1: the whole extension folder, and this machine's entries. *)
let delete ~(domain : Tsync_domain.Domain.t) ~engine ~lazy_tree ~confirm t =
  check_uses ~domain ~engine;
  if confirm <> Domain_name.to_string domain.name then
    Fail.invalid "deleting the vault needs the domain's name, %s"
      (Domain_name.to_string domain.name);
  let (module E : Engine.S) = engine in
  read_current engine ~lazy_tree;
  if E.kind ext = `Dir then E.remove_tree ext;
  (* §7.1: the vault is gone whatever the keystore does now. *)
    match forget ~domain ~secret_key:true t with
    | () -> None
    | exception Fail.E f ->
        Atomic.set t.key None;
        Atomic.set t.secret_key None;
        Some f.reason

let status ~domain ~engine ~lazy_tree t : Protocol.vault_status =
  check_uses ~domain ~engine;
  restore ~domain t;
  read_current engine ~lazy_tree;
  let found = read ~domain engine in
  let base =
    {
      Protocol.vault = `Absent;
      key_id = None;
      cached = None;
      slots = [];
      unusable = [];
      copies = found.copies;
      keystore_error = Atomic.get t.keystore_error;
      enrolled = false;
    }
  in
  match found.keyring with
    | `Absent ->
        gone ~domain t;
        base
    | `Corrupt reason -> { base with vault = `Corrupt reason }
    | `Ok k ->
        let kind = function
          | Keyring.Secret_key _ -> "secret-key"
          | Unknown _ -> "unknown"
        in
        let kinds = List.map kind k.slots in
        let unlocked = key t k <> None in
        {
          base with
          vault = (if unlocked then `Unlocked else `Locked);
          key_id = Some k.key_id;
          cached =
            (if not unlocked then None
             else (
               match Atomic.get t.cached with
                 | `Keystore -> Some "keystore"
                 | `Memory -> Some "memory"));
          slots =
            List.map
              (fun n -> (n, List.length (List.filter (( = ) n) kinds)))
              (List.sort_uniq compare kinds);
          unusable = Keyring.unusable k;
          enrolled =
            (match Atomic.get t.secret_key with
              | Some (id, _) -> Keyring.enrolls k ~secret_key_id:id
              | None -> false);
        }
