(** The keyring (spec extensions/vault §4): the data key K wrapped in slots. *)

type kdf = { mem_kib : int; iterations : int; parallelism : int; salt : string }

type slot =
  | Passphrase of {
      id : string;
      kdf : kdf;
      nonce : string;
      wrapped : string;
      created : int;
    }
  | Unknown of { id : string; json : Yojson.Safe.t }
      (** A slot of a kind this version does not know: skipped by [unlock], kept
          through a rewrite. *)

(** [key_id] and slot ids are 16 lowercase hex. *)
type t = { key_id : string; slots : slot list }

(** The writers' recommended parameters, [salt] unused (§9). *)
val recommended : kdf

(** [Error] is the reason the keyring is CORRUPT. *)
val of_string : string -> (t, string) result

(** The canonical form: equal content gives equal bytes. *)
val to_string : t -> string

(** A new K, and a keyring with one passphrase slot wrapping it. *)
val create : ?params:kdf -> now:int -> string -> string * t

(** A new slot wrapping [key] under [passphrase] (raw bytes). *)
val passphrase_slot :
  ?params:kdf -> now:int -> key_id:string -> key:string -> string -> slot

(** K, from the first of the derivable passphrase slots (§4.2) that opens.
    [None] is a wrong passphrase. *)
val unlock : t -> string -> string option

(** Ids of the passphrase slots unlock skips: outside the readers' limits, or
    past [VAULT_MAX_SLOTS]. *)
val unusable : t -> string list

(** The fold of two copies with one key id (§4.3); [None] when the key ids
    differ. *)
val union : t -> t -> t option
