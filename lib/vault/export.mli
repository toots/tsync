(** A vault export (spec extensions/vault §8.2, §8.3): every record's plaintext,
    the vault's keys and appearance, sealed in one file.

    The owner gathers a {!payload} and seals it with {!seal_with_vault} (the
    user's export) or {!seal_to_backup} (a scheduled backup); an import reads
    the file's {!header} to know what to ask for, then opens it with
    {!open_with_vault} or {!open_with_backup}. *)

type record = { extension : string; name : string; plaintext : string }

(** [records] as their envelopes opened, [extension] naming each one's folder;
    [keys] the vault's K first, then its retired keys, as [(key_id, key)];
    [appearance] and [backup_key] those files' text. *)
type payload = {
  created : int;
  domain : string;
  keys : (string * string) list;
  appearance : string option;
  backup_key : string option;
  records : record list;
}

(** What opens a file: the vault's passphrase with the secret key of that id, or
    the backup key of that id. *)
type header = [ `Secret_key of string | `Backup_key of string ]

(** [Error] says why the text is no export of this version. *)
val header : string -> (header, string) result

(** The file's text, sealed under Argon2id of [passphrase] with [secret_key], as
    a keyring slot is (§4.2). *)
val seal_with_vault :
  secret_key:string -> passphrase:string -> payload -> string

(** [`Wrong]: the passphrase or the secret key is not the one it was sealed
    with. *)
val open_with_vault :
  secret_key:string ->
  passphrase:string ->
  string ->
  (payload, [ `Wrong | `Corrupt of string ]) result

(** A backup key pair from its 16-byte seed, the part the user keeps. *)
type backup_key = { id : string; public : string }

val backup_key_of_seed : string -> backup_key

(** The text of the vault's record of a backup key, and its reading. *)
val backup_key_to_string : backup_key -> created:int -> string

val backup_key_of_string : string -> (backup_key, string) result

(** The file's text, sealed to the backup key's public half alone. *)
val seal_to_backup : backup_key -> payload -> string

(** [`Wrong]: the seed is not the backup key's it was sealed to. *)
val open_with_backup :
  seed:string -> string -> (payload, [ `Wrong | `Corrupt of string ]) result
