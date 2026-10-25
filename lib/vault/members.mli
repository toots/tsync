(** The members of a JSON object this version does not know, kept so a rewrite
    writes them back (passwords §2, totp §2, vault §4.1, §6.3, §8.1). *)
val unknown :
  known:string list ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list
