(** The vault's primitives (spec extensions/vault §4.2, §5), over the vendored
    Monocypher. *)

val key_size : int
val nonce_size : int
val tag_size : int

(** XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha): ciphertext followed by the
    tag. *)
val seal : key:string -> nonce:string -> ad:string -> string -> string

(** [None] when authentication fails. *)
val open_ : key:string -> nonce:string -> ad:string -> string -> string option

(** Argon2id version 0x13, 32-byte output. [secret] and [ad] exist for the RFC
    9106 test vector; the vault uses neither. Releases the runtime while it
    runs. *)
val argon2id :
  ?secret:string ->
  ?ad:string ->
  mem_kib:int ->
  iterations:int ->
  parallelism:int ->
  salt:string ->
  string ->
  string
