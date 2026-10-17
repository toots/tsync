(** A record body (spec extensions/vault §5). [key_id] is 16 lowercase hex. *)

(** A fresh nonce on every call. *)
val seal : key:string -> key_id:string -> extension:string -> string -> string

(** [`Other_key id] names the key id the body's header carries; whether that is
    "under another key" or CORRUPT depends on the keyring copies, which the
    caller holds. *)
val open_ :
  key:string ->
  key_id:string ->
  extension:string ->
  string ->
  (string, [ `Corrupt | `Other_key of string ]) result
