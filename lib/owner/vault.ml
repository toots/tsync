open Tsync_core
open Tsync_sync
module Keyring = Tsync_vault.Keyring
module Passphrase = Tsync_vault.Passphrase

let ext = Names.extension_root
let folder = Names.join ext "vault"
let keyring_path = Names.join folder "keyring"

(* vault §6: K lives in the owner's memory only, under its key id. *)
type t = { key : (string * string) option Atomic.t }

let create () = { key = Atomic.make None }

(* extensions README §3: a client that uses no extension of the domain runs
   none of the vault. *)
let check_uses (domain : Tsync_domain.Domain.t) =
  if domain.domain.extensions = [] then
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

(* README §4.2: a fold that cannot be applied now is left for the next. *)
let apply engine dir actions =
  let (module E : Engine.S) = engine in
  List.iter
    (fun action ->
      try
        match action with
          | Tsync_vault.Fold.Move { src; dst } ->
              E.rename ~src:(Names.join dir src) ~dst:(Names.join dir dst)
                ~exclusive:false
          | Remove name -> E.delete (Names.join dir name)
          | Write { name; body } ->
              write_file engine ~exclusive:false (Names.join dir name) body
      with Fail.E f -> Log.warn "vault: a fold in %s is left: %s" dir f.reason)
    actions

type found = {
  keyring : [ `Absent | `Corrupt of string | `Ok of Keyring.t ];
  copies : string list;  (** the conflicted copies beside it *)
}

let read engine =
  let (module E : Engine.S) = engine in
  let actions, others =
    Tsync_vault.Fold.keyring ~name:"keyring" (files engine folder)
  in
  apply engine folder actions;
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

let secret ~key_id passphrase : Protocol.secret =
  { passphrase = Passphrase.to_string passphrase; key_id }

let init t ~domain ~engine ~lazy_tree =
  check_uses domain;
  refresh engine ~lazy_tree;
  (match (read engine).keyring with
    | `Absent -> ()
    | `Ok _ | `Corrupt _ ->
        Fail.raise_ Exists "%s already has a vault: unlock it"
          (Domain_name.to_string domain.name));
  let passphrase = Passphrase.generate () in
  let key, keyring = Keyring.create ~now:(now ()) passphrase in
  write engine ~exclusive:true keyring;
  Atomic.set t.key (Some (keyring.key_id, key));
  secret ~key_id:keyring.key_id passphrase

let current engine ~lazy_tree =
  read_current engine ~lazy_tree;
  match (read engine).keyring with
    | `Ok k -> k
    | `Absent -> Fail.absent "this domain has no vault: run tsync vault init"
    | `Corrupt reason -> Fail.corrupt "the keyring is unreadable: %s" reason

let unlock t ~domain ~engine ~lazy_tree typed =
  check_uses domain;
  let passphrase =
    match Passphrase.of_string typed with
      | Some p -> p
      | None -> Fail.invalid "a passphrase is 26 characters in groups 5-5-5-5-6"
  in
  let keyring = current engine ~lazy_tree in
  match Keyring.unlock keyring passphrase with
    | Some key -> Atomic.set t.key (Some (keyring.key_id, key))
    | None -> Fail.raise_ Denied "wrong passphrase"

let lock t ~domain =
  check_uses domain;
  Atomic.set t.key None

(* The K held for the keyring's key id: one for another id is not adopted
   (vault §6). *)
let key t keyring =
  match Atomic.get t.key with
    | Some (id, key) when id = keyring.Keyring.key_id -> Some key
    | _ -> None

let held t ~domain ~engine ~lazy_tree =
  check_uses domain;
  let keyring = current engine ~lazy_tree in
  match key t keyring with
    | Some k -> (keyring, k)
    | None -> Fail.raise_ Locked "the vault is locked: run tsync vault unlock"

(* vault §7: a new slot replaces every passphrase slot; others are kept. *)
let passphrase t ~domain ~engine ~lazy_tree =
  let keyring, key = held t ~domain ~engine ~lazy_tree in
  let passphrase = Passphrase.generate () in
  let slot =
    Keyring.passphrase_slot ~now:(now ()) ~key_id:keyring.key_id ~key passphrase
  in
  let others =
    List.filter
      (function Keyring.Passphrase _ -> false | Unknown _ -> true)
      keyring.slots
  in
  write engine ~exclusive:false { keyring with slots = slot :: others };
  secret ~key_id:keyring.key_id passphrase

let status t ~domain ~engine ~lazy_tree : Protocol.vault_status =
  check_uses domain;
  read_current engine ~lazy_tree;
  let found = read engine in
  let base =
    {
      Protocol.vault = `Absent;
      key_id = None;
      cached = None;
      slots = [];
      unusable = [];
      copies = found.copies;
    }
  in
  match found.keyring with
    | `Absent -> base
    | `Corrupt reason -> { base with vault = `Corrupt reason }
    | `Ok k ->
        let kind = function
          | Keyring.Passphrase _ -> "passphrase"
          | Unknown _ -> "unknown"
        in
        let kinds = List.map kind k.slots in
        let unlocked = key t k <> None in
        {
          base with
          vault = (if unlocked then `Unlocked else `Locked);
          key_id = Some k.key_id;
          cached = (if unlocked then Some "memory" else None);
          slots =
            List.map
              (fun n -> (n, List.length (List.filter (( = ) n) kinds)))
              (List.sort_uniq compare kinds);
          unusable = Keyring.unusable k;
        }
