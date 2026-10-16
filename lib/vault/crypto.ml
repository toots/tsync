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

(* The stub hands these to Monocypher as they are: below RFC 9106's floor it
   divides by zero or writes past its work area. *)
let argon2id ?(secret = "") ?(ad = "") ~mem_kib ~iterations ~parallelism ~salt
    password =
  if
    parallelism < 1 || iterations < 1
    || mem_kib < 8 * parallelism
    || mem_kib > 1 lsl 22
  then invalid_arg "Crypto.argon2id: parameters outside RFC 9106";
  argon2id_raw password salt secret ad mem_kib iterations parallelism
