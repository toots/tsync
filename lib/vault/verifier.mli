(** The platform's way to verify the user is present and is the account's owner
    (spec extensions/passwords §9.2, [verify]): Touch ID or the account password
    on macOS. A host without one registers nothing. *)

type t = {
  name : string;  (** what a refusal names, as [LocalAuthentication] *)
  verify : reason:string -> (unit, string) result;
      (** blocks until the user answered; [Error] says why it did not verify,
          and [Fail.E] [Unreachable] that it could not ask now, which the
          extension answers with the passphrase *)
}

(** At module initialisation, by the host's library. *)
val register : t -> unit

val registered : unit -> t option
