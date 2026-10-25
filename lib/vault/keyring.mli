(** The keyring (spec extensions/vault §4): the data key K wrapped in slots. *)

type kdf = { mem_kib : int; iterations : int; parallelism : int; salt : string }

type slot =
  | Secret_key of {
      id : string;
      secret_key_id : string;
      kdf : kdf;
      nonce : string;
      wrapped : string;
      created : int;
      extra : (string * Yojson.Safe.t) list;
    }
      (** the passphrase with the secret key (§4.2); [extra] holds the members
          this version does not know, kept through a rewrite *)
  | Unknown of { id : string; json : Yojson.Safe.t }
      (** A slot of a kind this version does not know: skipped by [unlock], kept
          through a rewrite. *)

(** [key_id] and slot ids are 16 lowercase hex; [extra] holds the members this
    version does not know, kept through a rewrite. *)
type t = {
  key_id : string;
  slots : slot list;
  extra : (string * Yojson.Safe.t) list;
}

(** The writers' recommended parameters, [salt] unused (§9). *)
val recommended : kdf

(** [Error] is the reason the keyring is CORRUPT. *)
val of_string : string -> (t, string) result

(** The canonical form: equal content gives equal bytes. *)
val to_string : t -> string

(** A new K, and a keyring with one slot wrapping it under the passphrase
    (bytes, §2.2) and the secret key. *)
val create : ?params:kdf -> now:int -> secret_key:string -> string -> string * t

(** A new slot wrapping [key] under [passphrase] and [secret_key]. *)
val slot :
  ?params:kdf ->
  now:int ->
  key_id:string ->
  key:string ->
  secret_key:string ->
  string ->
  slot

(** K, from the first derivable slot of this secret key (§4.2) that opens. *)
val unlock :
  t ->
  secret_key:string ->
  string ->
  ( string,
    [ `Wrong_secret_key | `Wrong_passphrase | `Unusable of string list ] )
  result

(** Whether a slot is keyed with this secret key: a machine holding it is
    enrolled (§6). *)
val enrolls : t -> secret_key_id:string -> bool

(** Ids of the slots unlock skips: outside the readers' limits, or past
    [VAULT_MAX_SLOTS]. *)
val unusable : t -> string list

(** The fold of two copies with one key id (§4.3); [None] when the key ids
    differ, or the members this version does not know. *)
val union : t -> t -> t option
