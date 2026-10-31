(** The vault keystore on Windows (security-model §10.6): one generic credential
    per name, its target [tsync-vault:<hex16(XXH3(name))>:<keyId>], so a name
    holding [:] cannot match another's prefix. No call prompts. *)

(** Registers it as the host's keystore; the Windows platform module calls it at
    start. *)
val register : unit -> unit
