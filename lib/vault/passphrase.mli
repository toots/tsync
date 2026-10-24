(** The user's passphrase (spec extensions/vault §2.2). *)

val min_length : int

(** The bytes the KDF takes: surrounding white space removed, nothing else
    changed. [Error] when shorter than {!min_length} Unicode scalar values. *)
val of_typed : string -> (string, string) result
