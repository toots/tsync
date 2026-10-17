(** The host's keystore for vault keys (spec extensions/vault §6.1): one entry
    per domain, the key id and K of its last unlock. A host without one
    registers nothing, and K stays in the owner's memory. *)

(** Each call raises [Fail.E] with the keystore's reason when it fails. *)
type t = {
  name : string;  (** what status names, as [keychain] *)
  put : domain:string -> key_id:string -> key:string -> unit;
      (** replaces the domain's entry *)
  get : domain:string -> (string * string) option;  (** key id and K *)
  delete : domain:string -> unit;
}

(** At module initialisation, by the host's library. *)
val register : t -> unit

val registered : unit -> t option
