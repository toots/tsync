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

(** Argon2id version 0x13, 32-byte output. [secret] is the vault's secret key
    (vault §4.2); [ad] exists for the RFC 9106 test vector. Releases the runtime
    while it runs. [Invalid_argument] for [parallelism] or [iterations] below 1,
    [mem_kib] below [8 * parallelism] or above 1 GiB, which a 32-bit size can
    hold. *)
val argon2id :
  ?secret:string ->
  ?ad:string ->
  mem_kib:int ->
  iterations:int ->
  parallelism:int ->
  salt:string ->
  string ->
  string
