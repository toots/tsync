(** The passkey authenticator (spec extensions/passwords §7.2, §7.3): the bytes
    WebAuthn exchanges, and the check that an RP ID belongs to an origin. Pure:
    the private key is given, never stored here. *)

(** §7.2. *)
val aaguid : string
(** 16 bytes *)

(** COSE algorithm identifiers this authenticator supports, in preference order:
    [[-7]] (ES256). *)
val supported : int list

(** A fresh P-256 private scalar, 32 bytes, from the CSPRNG. *)
val generate_key : unit -> string

(** The public key of a private scalar as SubjectPublicKeyInfo DER, for a
    client's [getPublicKey()]. *)
val public_key_spki : string -> string

type flags = { user_verified : bool }

(** Authenticator data (WebAuthn §6.1): rpIdHash, flags UP BE BS (and UV, and AT
    with [attested]), counter 0, and on creation the attested credential data
    with the public key as a COSE_Key. *)
val authenticator_data :
  ?attested:string * string -> rp_id:string -> flags -> unit -> string
(** [attested] is (credential id, private scalar). *)

(** The attestation object, [fmt] "none", deterministic CBOR (§7.2). *)
val attestation_object : authenticator_data:string -> string

(** ES256 over [authenticator_data ‖ client_data_hash], DER-encoded. *)
val sign :
  private_key:string ->
  authenticator_data:string ->
  client_data_hash:string ->
  string

(** §7.3: [Ok ()] when [origin] is https (or http://localhost) and [rp_id] is
    its host or a suffix of it at a label boundary that is not a public suffix;
    [Error] says why, naming no secret. *)
val rp_id_allowed : origin:string -> rp_id:string -> (unit, string) result

(** Whether a host or suffix is a public suffix, by the bundled list. *)
val is_public_suffix : string -> bool
