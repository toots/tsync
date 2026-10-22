open Tsync_core
open Tsync_sync
module Keyring = Tsync_vault.Keyring
module Passphrase = Tsync_vault.Passphrase
module Secret_key = Tsync_vault.Secret_key

let ext = Names.extension_root
let folder = Names.join ext "vault"
let keyring_path = Names.join folder "keyring"

(* §8.1: a folder of its own, so the keyring's fold never takes it for a copy. *)
let appearance_folder = Names.join folder "appearance"
let appearance_path = Names.join appearance_folder "appearance"

(* §6.3: a folder of its own, like the appearance's. *)
let machines_folder = Names.join folder "machines"

(* §6.2: when K was adopted, and last used for the user. *)
type since = { unlocked_at : float; last_use : float }

(* vault §6: K under its key id and the secret key under its id, in the owner's
   memory and, where the host has one, its keystore (§6.1). *)
type t = {
  key : (string * string) option Atomic.t;
  since : since option Atomic.t;  (** set with [key], §6.2's clocks *)
  locked_by : [ `Idle | `Screen | `Age ] option Atomic.t;
      (** §6.2: why the policy locked it, until the next unlock *)
  watching : bool Atomic.t;  (** §6.2: a watcher runs while K is held *)
  announced : string list Atomic.t;
      (** §6.3: the new machines' names, as last read, for the domain's status
      *)
  secret_key : (string * string) option Atomic.t;
  cached : [ `Keystore | `Memory ] Atomic.t;
  keystore_read : [ `Unread | `Read | `Failed of float ] Atomic.t;
      (** [`Failed at]: the last read failed at [at], with no K held since *)
  keystore_error : string option Atomic.t;
  pulls : Pulls.t option;  (** on a lazy tree: reads answer the last view *)
  view : Pulls.view Atomic.t;  (** of the last read *)
}

let create ?pulls () =
  {
    key = Atomic.make None;
    since = Atomic.make None;
    locked_by = Atomic.make None;
    watching = Atomic.make false;
    announced = Atomic.make [];
    secret_key = Atomic.make None;
    cached = Atomic.make `Memory;
    keystore_read = Atomic.make `Unread;
    keystore_error = Atomic.make None;
    pulls;
    view = Atomic.make { Pulls.pulled_at = None; outdated = false };
  }

(* README §4.5. *)
let record_keep = 30. *. 86400.

(* §6.1: two entries per domain, named apart; no domain name holds a [/]. *)
let key_entry (domain : Tsync_domain.Domain.t) =
  Domain_name.to_string domain.name

let secret_key_entry domain = key_entry domain ^ "/secret-key"

(* security-model §10.6: what was opened under a K goes with it. Registered at
   module initialisation, called with the domain's name. *)
let forgotten : (string -> unit) list Atomic.t = Atomic.make []
let when_forgotten f = Atomic.set forgotten (f :: Atomic.get forgotten)

(* §6.1: once K was held or dropped on purpose, the keystore is not read again,
   so an entry its delete left behind never comes back. *)
let drop_key ~domain t =
  Atomic.set t.keystore_read `Read;
  Atomic.set t.key None;
  Atomic.set t.since None;
  Atomic.set t.announced [];
  List.iter (fun f -> f (key_entry domain)) (Atomic.get forgotten)

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
  if key_failure = None then drop_key ~domain t;
  let secret_key_failure =
    if secret_key then deleted (secret_key_entry domain) else None
  in
  if secret_key && secret_key_failure = None then Atomic.set t.secret_key None;
  match (key_failure, secret_key_failure) with
    | Some (name, reason), _ | None, Some (name, reason) ->
        Fail.raise_ Unexplained "%s could not forget the key: %s" name reason
    | None, None -> ()

(* §6.2: what the main last stated, never waiting to ask it. *)
let policy ~(domain : Tsync_domain.Domain.t) ~engine =
  let (module E : Engine.S) = engine in
  Tsync_config.Config.vault_lock_in_force domain.domain
    (try E.stated_settings () with Fail.E _ -> None)

let auto_locks ~domain ~engine =
  not (Vault_lock.is_none (policy ~domain ~engine))

(* §6.2: while a policy is in force no K entry stays in the keystore. *)
let clear_keystore_key ~domain t =
  Option.iter
    (fun (ks : Keystore.t) ->
      match ks.delete ~domain:(key_entry domain) with
        | () -> Atomic.set t.cached `Memory
        | exception Fail.E f ->
            Log.warn "vault: %s keeps a key auto-lock should drop: %s" ks.name
              f.reason)
    (Keystore.registered ())

let lock_for ~domain t reason =
  match forget ~domain ~secret_key:false t with
    | () -> Atomic.set t.locked_by (Some reason)
    | exception Fail.E f ->
        Log.warn "vault: %s could not lock: %s" (key_entry domain) f.reason

(* §6.2: seconds in a policy's minute; a test shortens it. *)
let minute = Atomic.make 60.

(* §6.2: the idle and age limits, checked before K is used and by {!adopt}'s
   watcher, which also enforces a policy learned while K is held. *)
let expire ~domain ~engine t =
  let p = policy ~domain ~engine in
  if not (Vault_lock.is_none p) then (
    if Atomic.get t.cached = `Keystore then clear_keystore_key ~domain t;
    match Atomic.get t.since with
      | None -> ()
      | Some since ->
          let now = Rt.now () and m = Atomic.get minute in
          let past limit from scale =
            match limit with
              | Some n -> now -. from >= float_of_int n *. scale
              | None -> false
          in
          if past p.idle_minutes since.last_use m then lock_for ~domain t `Idle
          else if past p.max_hours since.unlocked_at (60. *. m) then
            lock_for ~domain t `Age)

let adopt ~domain ~engine t entry =
  let now = Rt.now () in
  Atomic.set t.key (Some entry);
  Atomic.set t.since (Some { unlocked_at = now; last_use = now });
  if Atomic.compare_and_set t.watching false true then
    Rt.spawn ~name:"vault auto-lock" (fun () ->
        let rec loop () =
          match Stop.sleep (Float.min 10. (Atomic.get minute /. 4.)) with
            | exception Stop.Stopping -> Atomic.set t.watching false
            | () ->
                Format_merge.locked folder (fun () -> expire ~domain ~engine t);
                if Atomic.get t.key <> None then loop ()
                else (
                  Atomic.set t.watching false;
                  (* An unlock between the check and the flag found it set. *)
                  if
                    Atomic.get t.key <> None
                    && Atomic.compare_and_set t.watching false true
                  then loop ())
        in
        loop ())

(* §9 [VAULT_KEYSTORE_RETRY]; a test shortens it. *)
let keystore_retry = Atomic.make 60.

(* §6.1 owner start: read before the first use of either secret, and again after
   a failed read while no K is held, at most once per [keystore_retry]. *)
let restore ~domain ~engine t =
  let auto_locks = auto_locks ~domain ~engine in
  let seen = Atomic.get t.keystore_read in
  let due =
    match seen with
      | `Unread -> true
      | `Failed at ->
          Atomic.get t.key = None
          && Rt.now () -. at >= Atomic.get keystore_retry
      | `Read -> false
  in
  if due && Atomic.compare_and_set t.keystore_read seen `Read then (
    if auto_locks then clear_keystore_key ~domain t;
    Option.iter
      (fun (ks : Keystore.t) ->
        match
          ( ks.get ~domain:(key_entry domain),
            ks.get ~domain:(secret_key_entry domain) )
        with
          | key, secret_key ->
              Atomic.set t.keystore_error None;
              (* §6: a read never replaces a K the owner already holds. *)
              if not auto_locks then
                Option.iter
                  (fun entry ->
                    if Atomic.get t.key = None then (
                      adopt ~domain ~engine t entry;
                      Atomic.set t.cached `Keystore))
                  key;
              Option.iter
                (fun entry ->
                  ignore (Atomic.compare_and_set t.secret_key None (Some entry)))
                secret_key
          | exception Fail.E f ->
              Atomic.set t.keystore_error (Some f.reason);
              Atomic.set t.keystore_read (`Failed (Rt.now ())))
      (Keystore.registered ()))

(* §7.2: a re-key keeps the new secret key before its records are re-encrypted,
   so a machine whose re-encryption failed can still unlock and resume. *)
let keep_secret_key ~domain t secret_key =
  Atomic.set t.secret_key (Some (Secret_key.id secret_key, secret_key));
  Option.iter
    (fun (ks : Keystore.t) ->
      try
        ks.put ~domain:(secret_key_entry domain)
          ~key_id:(Secret_key.id secret_key) ~key:secret_key
      with Fail.E f ->
        Atomic.set t.keystore_error (Some f.reason);
        Log.warn "vault: %s keeps the secret key in memory: %s" ks.name f.reason)
    (Keystore.registered ())

(* §6.1 unlock: a keystore that refuses leaves both in memory. *)
let store ~domain ~engine t ~key:(key_id, key) ~secret_key =
  let auto_locks = auto_locks ~domain ~engine in
  Atomic.set t.keystore_read `Read;
  adopt ~domain ~engine t (key_id, key);
  Atomic.set t.locked_by None;
  Atomic.set t.secret_key (Some (Secret_key.id secret_key, secret_key));
  Atomic.set t.cached `Memory;
  Option.iter
    (fun (ks : Keystore.t) ->
      match
        if not auto_locks then ks.put ~domain:(key_entry domain) ~key_id ~key;
        ks.put ~domain:(secret_key_entry domain)
          ~key_id:(Secret_key.id secret_key) ~key:secret_key
      with
        | () ->
            if auto_locks then clear_keystore_key ~domain t
            else Atomic.set t.cached `Keystore;
            Atomic.set t.keystore_error None
        | exception Fail.E f ->
            Atomic.set t.keystore_error (Some f.reason);
            Log.warn "vault: %s keeps the keys in memory: %s" ks.name f.reason)
    (Keystore.registered ())

(* extensions README §3, 05 §2.1 rule 5: the configured list, else the one the
   main states, names this release does not know dropped. *)
let extensions ~(domain : Tsync_domain.Domain.t) ~engine =
  let (module E : Engine.S) = engine in
  (* extensions README §3: what the main states is asked before deciding, so a
     client that has not learned it yet never reads it as stating nothing. *)
  Tsync_config.Config.extensions_in_force domain.domain
    (E.stated_settings ~wait:true ())

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

let vault_folders = [""; ext; folder; appearance_folder; machines_folder]

(* README §4.1: a keyring write needs the current keyring; a failed pull fails
   the verb. *)
let pull (module E : Engine.S) =
  List.iter
    (fun dir -> if E.kind dir = `Dir then ignore (E.pull dir))
    vault_folders

(* vault §3 step 2: init first brings the local tree to the main's. *)
let refresh engine ~lazy_tree =
  let (module E : Engine.S) = engine in
  if lazy_tree then pull engine else ignore (E.resync ())

(* README §4.1: a read answers the last view of the folders after the pull
   patience, a folder never pulled waits for its pull, and the oldest view
   read is what the reply says. *)
let read_folders ?(pull = `Auto) engine t dirs =
  let (module E : Engine.S) = engine in
  match t.pulls with
    | None -> ()
    | Some pulls ->
        let view =
          List.fold_left
            (fun (acc : Pulls.view) dir ->
              if E.kind dir <> `Dir then acc
              else (
                let v = Pulls.for_listing pulls ~pull dir in
                E.hold_views dir ~until:(Unix.gettimeofday () +. record_keep);
                {
                  outdated = acc.outdated || v.outdated;
                  pulled_at =
                    (match (acc.pulled_at, v.pulled_at) with
                      | Some a, Some b -> Some (Float.min a b)
                      | a, None | None, a -> a);
                }))
            { pulled_at = None; outdated = false }
            dirs
        in
        Atomic.set t.view view

let read_current ?pull engine ~lazy_tree t =
  if lazy_tree then read_folders ?pull engine t vault_folders

(* README §4.1: a record write proceeds on the last view, pushed later. *)
let before_write t dir =
  Option.iter (fun pulls -> Pulls.before_mutation pulls dir) t.pulls

(* §4.3: every extension's folder, whether this client uses it or not. *)
let extension_folders engine ~lazy_tree t =
  let (module E : Engine.S) = engine in
  if E.kind ext <> `Dir then []
  else
    List.filter_map
      (fun (e : E.entry) ->
        if (not e.is_dir) || Names.join ext e.name = folder then None
        else (
          let dir = Names.join ext e.name in
          if lazy_tree then before_write t dir;
          Some (e.name, dir)))
      (E.list_children ext)

(* The files of an extension folder, read whole. [keep]: on a lazy tree each
   body stays pinned, so the last view stays whole offline (README §4.1). *)
let files ?(keep = false) engine dir : Tsync_vault.Fold.file list =
  let (module E : Engine.S) = engine in
  if E.kind dir <> `Dir then []
  else
    List.filter_map
      (fun (e : E.entry) ->
        if e.is_dir then None
        else (
          let path = Names.join dir e.name in
          let body = read_file engine path in
          if keep then E.pin path ~keep:record_keep;
          Some { Tsync_vault.Fold.name = e.name; body }))
      (E.list_children dir)

type found = {
  keyring : [ `Absent | `Corrupt of string | `Ok of Keyring.t ];
  copies : string list;  (** the conflicted copies beside it *)
}

(* §8: the keyring's fold runs only where this client may write the domain. *)
let read ~(domain : Tsync_domain.Domain.t) engine =
  let (module E : Engine.S) = engine in
  let actions, others =
    Tsync_vault.Fold.keyring ~name:"keyring"
      (files ~keep:domain.lazy_tree engine folder)
  in
  if not domain.domain.read_only then
    ignore (Format_merge.apply engine folder actions);
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
  Format_merge.write_file engine ~exclusive keyring_path
    (Keyring.to_string keyring)

let now () = int_of_float (Unix.time ())

let secret ~key_id secret_key : Protocol.secret =
  { secret_key = Secret_key.to_string secret_key; key_id }

let chosen typed =
  match Passphrase.of_typed typed with
    | Ok passphrase -> passphrase
    | Error reason -> Fail.invalid "%s" reason

let machine_path domain =
  Names.join machines_folder (Tsync_domain.Domain.client_uuid domain)

let host_name () = try Unix.gethostname () with Unix.Unix_error _ -> "tsync"

(* §6.3: every entry by client uuid; [None] for one that does not open. *)
let machines engine ~key_id ~key =
  List.map
    (fun (f : Tsync_vault.Fold.file) ->
      ( f.name,
        match
          Tsync_vault.Envelope.open_ ~key ~key_id ~extension:"vault" f.body
        with
          | Ok plaintext ->
              Result.to_option (Tsync_vault.Machine.of_string plaintext)
          | Error _ -> None ))
    (files engine machines_folder)

let write_machine ~domain engine ~key_id ~key (m : Tsync_vault.Machine.t) =
  let (module E : Engine.S) = engine in
  List.iter
    (fun dir -> E.mkdir dir ~exclusive:false)
    [ext; folder; machines_folder];
  Format_merge.write_file engine ~exclusive:false (machine_path domain)
    (Tsync_vault.Envelope.seal ~key ~key_id ~extension:"vault"
       (Tsync_vault.Machine.to_string m))

(* §6.3: this machine's entry, written when it enrolls and refreshed by an
   unlock once a day old. The list is informative: a domain this client cannot
   write keeps none, and a failure only logs. *)
let note_machine ?(enrolls = false) ~(domain : Tsync_domain.Domain.t) ~engine
    ~lazy_tree t ~key_id ~key =
  if not domain.domain.read_only then (
    try
      if lazy_tree then before_write t machines_folder;
      let now = now () in
      let entries = machines engine ~key_id ~key in
      match
        Option.join
          (List.assoc_opt (Tsync_domain.Domain.client_uuid domain) entries)
      with
        | Some m when (not enrolls) && now - m.last_unlock < 86400 -> ()
        | Some m ->
            write_machine ~domain engine ~key_id ~key
              { m with last_unlock = now; modified = now }
        | None ->
            write_machine ~domain engine ~key_id ~key
              {
                name = host_name ();
                enrolled = now;
                last_unlock = now;
                seen = List.map fst entries;
                modified = now;
              }
    with Fail.E f ->
      Log.warn "vault: this machine's entry is left: %s" f.reason)

(* §6.3: the entries this machine has not acknowledged, read again at an unlock,
   a listing, a status and when the folder changes; the domain's status reports
   what was last read, so a menu that polls it reads no file. *)
let announce ~domain ~engine t =
  restore ~domain ~engine t;
  let names =
    match (read ~domain engine).keyring with
      | `Ok k -> (
          match Atomic.get t.key with
            | Some (id, key) when id = k.Keyring.key_id -> (
                let entries = machines engine ~key_id:id ~key in
                let me = Tsync_domain.Domain.client_uuid domain in
                match Option.join (List.assoc_opt me entries) with
                  | None -> []
                  | Some own ->
                      List.filter_map
                        (fun (id, m) ->
                          match m with
                            | Some (m : Tsync_vault.Machine.t)
                              when id <> me && not (List.mem id own.seen) ->
                                Some m.name
                            | _ -> None)
                        entries)
            | _ -> [])
      | _ -> []
  in
  Atomic.set t.announced names;
  names

let announced t = Atomic.get t.announced

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
  store ~domain ~engine t ~key:(keyring.key_id, key) ~secret_key;
  note_machine ~enrolls:true ~domain ~engine ~lazy_tree t ~key_id:keyring.key_id
    ~key;
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

(* [strict]: a keyring write, which needs the current keyring (README §4.1). *)
let current ?(strict = false) ?pull:mode ~domain engine ~lazy_tree t =
  if strict && lazy_tree then pull engine
  else read_current ?pull:mode engine ~lazy_tree t;
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
let reencrypt ~engine ~lazy_tree ~from:(old_id, old_key) ~into:(key_id, key) t =
  let module Envelope = Tsync_vault.Envelope in
  List.iter
    (fun (extension, dir) ->
      List.iter
        (fun (f : Tsync_vault.Fold.file) ->
          match
            Envelope.open_ ~key:old_key ~key_id:old_id ~extension f.body
          with
            | Ok plaintext ->
                Format_merge.write_file engine ~exclusive:false
                  (Names.join dir f.name)
                  (Envelope.seal ~key ~key_id ~extension plaintext)
            | Error _ -> ())
        (files engine dir))
    (extension_folders engine ~lazy_tree t);
  let copies =
    List.filter_map
      (fun (f : Tsync_vault.Fold.file) ->
        match Keyring.of_string f.body with
          | Ok k when f.name <> "keyring" && k.key_id = old_id ->
              Some (Tsync_vault.Fold.Remove f.name)
          | _ -> None)
      (files engine folder)
  in
  ignore (Format_merge.apply engine folder copies)

let unlock ?secret_key ~domain ~engine ~lazy_tree t typed =
  let enrolls = secret_key <> None in
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  let keyring, key, secret_key =
    unwrap ?secret_key ~domain ~engine ~lazy_tree t typed
  in
  (* §4.3: the old K is dropped only once its records are re-encrypted; a
     failure here leaves it held for the next unlock. *)
  (match Atomic.get t.key with
    | Some ((old_id, _) as old) when old_id <> keyring.key_id ->
        reencrypt ~engine ~lazy_tree ~from:old ~into:(keyring.key_id, key) t
    | _ -> ());
  store ~domain ~engine t ~key:(keyring.key_id, key) ~secret_key;
  note_machine ~enrolls ~domain ~engine ~lazy_tree t ~key_id:keyring.key_id ~key;
  ignore (announce ~domain ~engine t)

(* totp §5: the user's own request, told apart by the passphrase. *)
let confirm ~domain ~engine ~lazy_tree t typed =
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  ignore (unwrap ~domain ~engine ~lazy_tree t typed)

let lock ?(forget_secret_key = false) ~domain ~engine ~lazy_tree:_ t =
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  forget ~domain ~secret_key:forget_secret_key t;
  (* §6.3: a machine leaving the vault takes its entry with it. *)
  if forget_secret_key && not domain.Tsync_domain.Domain.domain.read_only then (
    let (module E : Engine.S) = engine in
    try
      if E.kind (machine_path domain) = `File then
        E.delete (machine_path domain)
    with Fail.E f ->
      Log.warn "vault: this machine's entry is left: %s" f.reason)

(* §6.2: a host's report, acted on only under a policy that asks for it. *)
let screen_locked ~domain ~engine ~lazy_tree:_ t =
  if (policy ~domain ~engine).on_screen_lock && Atomic.get t.key <> None then
    lock_for ~domain t `Screen

(* The K held for the keyring's key id: one for another id is not adopted
   (vault §6). *)
let key t keyring =
  match Atomic.get t.key with
    | Some (id, key) when id = keyring.Keyring.key_id -> Some key
    | _ -> None

let held ?(use = true) ?strict ?pull ~domain ~engine ~lazy_tree t =
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  expire ~domain ~engine t;
  let keyring = current ?strict ?pull ~domain engine ~lazy_tree t in
  match key t keyring with
    | Some k ->
        if use then (
          match Atomic.get t.since with
            | Some since ->
                Atomic.set t.since (Some { since with last_use = Rt.now () })
            | None -> ());
        (keyring, k)
    | None -> Fail.raise_ Locked "the vault is locked: run tsync vault unlock"

(* vault §7: a new slot replaces every [secret-key] slot; others are kept. *)
let passphrase ?(new_secret_key = false) ~domain ~engine ~lazy_tree t typed =
  let keyring, key = held ~strict:true ~domain ~engine ~lazy_tree t in
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
    store ~domain ~engine t ~key:(keyring.key_id, key) ~secret_key;
    Some (secret ~key_id:keyring.key_id secret_key))
  else None

(* §6.3: the list, which acknowledges every enrolment it shows; [name] renames
   this machine's entry. *)
let list_machines ?name ~domain ~engine ~lazy_tree t : Protocol.machine list =
  let keyring, key = held ~domain ~engine ~lazy_tree t in
  if lazy_tree then read_folders engine t [machines_folder];
  let key_id = keyring.key_id in
  Option.iter
    (fun n ->
      if n = "" || String.length n > 256 then
        Fail.invalid "a machine's name is 1 to 256 bytes")
    name;
  note_machine ~enrolls:false ~domain ~engine ~lazy_tree t ~key_id ~key;
  let entries = machines engine ~key_id ~key in
  let me = Tsync_domain.Domain.client_uuid domain in
  let ids = List.map fst entries in
  (match Option.join (List.assoc_opt me entries) with
    | Some own
      when List.exists (fun id -> not (List.mem id own.seen)) ids
           || name <> None ->
        if not domain.domain.read_only then
          write_machine ~domain engine ~key_id ~key
            {
              own with
              seen = ids;
              name = Option.value ~default:own.name name;
              modified = now ();
            }
    | _ -> ());
  Atomic.set t.announced [];
  List.map
    (fun (id, m) ->
      let m =
        if id = me then
          Option.map
            (fun (m : Tsync_vault.Machine.t) ->
              { m with name = Option.value ~default:m.name name })
            m
        else m
      in
      {
        Protocol.uuid = id;
        this = id = me;
        entry =
          Option.map
            (fun (m : Tsync_vault.Machine.t) ->
              {
                Protocol.name = m.name;
                enrolled = m.enrolled;
                last_unlock = m.last_unlock;
              })
            m;
      })
    (List.sort compare entries)

(* §3.1: the secret key this machine is enrolled with, to the passphrase. *)
let kit ~domain ~engine ~lazy_tree t typed =
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  let keyring = current ~domain engine ~lazy_tree t in
  match Atomic.get t.secret_key with
    | Some (id, secret_key) when Keyring.enrolls keyring ~secret_key_id:id ->
        ignore (unwrap ~domain ~engine ~lazy_tree t typed);
        secret ~key_id:keyring.key_id secret_key
    | _ ->
        Fail.raise_ Locked
          "this machine is not enrolled: unlock it with the secret key"

(* §7.2: a new K, key id and secret key; the old K is kept until every record
   is re-encrypted, and a failure there is resumed at the next unlock. *)
let rekey ?new_passphrase ~domain ~engine ~lazy_tree t typed : Protocol.rekeyed
    =
  let keyring, old_key = held ~strict:true ~domain ~engine ~lazy_tree t in
  (match Atomic.get t.secret_key with
    | Some (id, _) when Keyring.enrolls keyring ~secret_key_id:id -> ()
    | _ ->
        Fail.raise_ Locked
          "this machine is not enrolled: unlock it with the secret key");
  ignore (unwrap ~domain ~engine ~lazy_tree t typed);
  let passphrase = chosen (Option.value ~default:typed new_passphrase) in
  let own =
    Option.join
      (List.assoc_opt
         (Tsync_domain.Domain.client_uuid domain)
         (machines engine ~key_id:keyring.key_id ~key:old_key))
  in
  let secret_key = Secret_key.generate () in
  let key, next = Keyring.create ~now:(now ()) ~secret_key passphrase in
  write engine ~exclusive:false next;
  keep_secret_key ~domain t secret_key;
  let pending =
    match
      reencrypt ~engine ~lazy_tree ~from:(keyring.key_id, old_key)
        ~into:(next.key_id, key) t
    with
      | () ->
          store ~domain ~engine t ~key:(next.key_id, key) ~secret_key;
          None
      | exception Fail.E f ->
          Log.warn "vault: the re-key's re-encryption is left: %s" f.reason;
          Some f.reason
  in
  (* §7.2: the list starts again with this machine alone. *)
  if pending = None && not domain.domain.read_only then (
    let (module E : Engine.S) = engine in
    try
      let me = Filename.basename (machine_path domain) in
      List.iter
        (fun (f : Tsync_vault.Fold.file) ->
          if f.name <> me then E.delete (Names.join machines_folder f.name))
        (files engine machines_folder);
      let now = now () in
      write_machine ~domain engine ~key_id:next.key_id ~key
        (match own with
          | Some m -> { m with last_unlock = now; seen = [me]; modified = now }
          | None ->
              {
                name = host_name ();
                enrolled = now;
                last_unlock = now;
                seen = [me];
                modified = now;
              })
    with Fail.E f -> Log.warn "vault: the machine list is left: %s" f.reason);
  Atomic.set t.announced [];
  { secret = secret ~key_id:next.key_id secret_key; pending }

(* vault §7.1: the whole extension folder, and this machine's entries. *)
let delete ~(domain : Tsync_domain.Domain.t) ~engine ~lazy_tree ~confirm t =
  check_uses ~domain ~engine;
  if confirm <> Domain_name.to_string domain.name then
    Fail.invalid "deleting the vault needs the domain's name, %s"
      (Domain_name.to_string domain.name);
  let (module E : Engine.S) = engine in
  if lazy_tree then pull engine;
  if E.kind ext = `Dir then E.remove_tree ext;
  (* §7.1: the vault is gone whatever the keystore does now. *)
    match forget ~domain ~secret_key:true t with
    | () -> None
    | exception Fail.E f ->
        drop_key ~domain t;
        Atomic.set t.secret_key None;
        Some f.reason

(* §8.1: the newest of the file and its conflicted copies; one that does not
   read is passed over. *)
let read_appearance engine =
  List.fold_left
    (fun (best : Tsync_vault.Appearance.t) (f : Tsync_vault.Fold.file) ->
      match Tsync_vault.Appearance.of_string f.body with
        | Ok a when a.modified >= best.modified -> a
        | _ -> best)
    Tsync_vault.Appearance.none
    (files engine appearance_folder)

(* §8.1: a vault write, on an unlocked vault; the copies beside the file go. *)
let set_appearance ~domain ~engine ~lazy_tree t ~color ~icon =
  let (module E : Engine.S) = engine in
  ignore (held ~domain ~engine ~lazy_tree t);
  if lazy_tree && E.kind appearance_folder = `Dir then
    before_write t appearance_folder;
  let current = read_appearance engine in
  let change field set = function
    | `Keep -> field
    | `Clear -> None
    | `Set v -> (
        match set v with
          | Ok v -> Some v
          | Error reason -> Fail.invalid "%s" reason)
  in
  let next : Tsync_vault.Appearance.t =
    {
      color = change current.color Tsync_vault.Appearance.check_color color;
      icon = change current.icon Tsync_vault.Appearance.check_icon icon;
      modified = max (now ()) (current.modified + 1);
    }
  in
  List.iter
    (fun dir -> E.mkdir dir ~exclusive:false)
    [ext; folder; appearance_folder];
  Format_merge.write_file engine ~exclusive:false appearance_path
    (Tsync_vault.Appearance.to_string next);
  List.iter
    (fun (f : Tsync_vault.Fold.file) ->
      if f.name <> "appearance" then
        E.delete (Names.join appearance_folder f.name))
    (files engine appearance_folder)

let status ?pull ~domain ~engine ~lazy_tree t : Protocol.vault_status =
  check_uses ~domain ~engine;
  restore ~domain ~engine t;
  read_current ?pull engine ~lazy_tree t;
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
      outdated = (Atomic.get t.view).outdated;
      pulled_at = (Atomic.get t.view).pulled_at;
      appearance = None;
      auto_lock =
        (let policy = policy ~domain ~engine in
         if Vault_lock.is_none policy then None
         else (
           let (module E : Engine.S) = engine in
           Some
             {
               Protocol.policy;
               from =
                 Tsync_config.Config.vault_lock_sources domain.domain
                   (try E.stated_settings () with Fail.E _ -> None);
             }));
      locked_by = Atomic.get t.locked_by;
      new_machines = [];
      secret_key_replaced = false;
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
          appearance =
            (let a = read_appearance engine in
             Some
               {
                 Protocol.color =
                   Tsync_vault.Appearance.color a ~key_id:k.key_id;
                 color_chosen = a.color <> None;
                 icon = a.icon;
               });
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
          (* §7.2: a secret key that opens no slot was replaced elsewhere. *)
          secret_key_replaced =
            (match Atomic.get t.secret_key with
              | Some (id, _) -> not (Keyring.enrolls k ~secret_key_id:id)
              | None -> false);
          new_machines = announce ~domain ~engine t;
        }
