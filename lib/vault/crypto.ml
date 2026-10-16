external seal : string -> string -> string -> string -> string
  = "tsync_vault_seal"

external open_ : string -> string -> string -> string -> string option
  = "tsync_vault_open"

external argon2id_raw :
  string -> string -> string -> string -> int -> int -> int -> string
  = "tsync_vault_argon2id_bytecode" "tsync_vault_argon2id_native"

let key_size = 32
let nonce_size = 24
let tag_size = 16

let check name size s =
  if String.length s <> size then
    invalid_arg (Printf.sprintf "Crypto: %s must be %d bytes" name size)

let seal ~key ~nonce ~ad plaintext =
  check "key" key_size key;
  check "nonce" nonce_size nonce;
  seal key nonce ad plaintext

let open_ ~key ~nonce ~ad sealed =
  check "key" key_size key;
  check "nonce" nonce_size nonce;
  open_ key nonce ad sealed

let argon2id ?(secret = "") ?(ad = "") ~mem_kib ~iterations ~parallelism ~salt
    password =
  argon2id_raw password salt secret ad mem_kib iterations parallelism
