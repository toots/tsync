(** The wire contract between the http-proxy backend (client) and frontend
    (server): request authentication, and how keys and listings are encoded.

    No transport here — cohttp lives on either side; this module exists so the
    two halves cannot drift. *)

(** HMAC-SHA256 over a shared secret. *)
module Auth : sig
  val timestamp_header : string
  val signature_header : string

  (** Headers to send with a request. [timestamp] defaults to now; passing one
      signs under a time of the caller's choosing, which is how the replay
      window is exercised — the signature is genuine and only the clock is
      wrong. *)
  val request_headers :
    ?timestamp:string ->
    secret:string ->
    meth:string ->
    path:string ->
    body:Bigstring.t ->
    unit ->
    (string * string) list

  (** Whether a request's signature holds and its timestamp is within the replay
      window (five minutes; both clocks are assumed roughly in sync).

      The signature covers method, request target, timestamp and a hash of the
      body, so a captured one cannot be replayed against a different request.
      Compared in constant time. *)
  val verify :
    secret:string ->
    meth:string ->
    path:string ->
    timestamp:string ->
    signature:string ->
    body:Bigstring.t ->
    bool
end

(** The long-poll parameters. Here rather than spelled at each end because that
    is what this module is for: the client sets them and the frontend reads
    them, and nothing but agreement makes the exchange work. *)
module Watch : sig
  (** How long a client asks a peer to hold a request open, and the longest a
      peer will agree to hold one. One value, so a client cannot ask for more
      than a peer would give: it is clamped to this either way. *)
  val max_seconds : float

  val wait_param : string
  val last_seen_param : string

  (** Set by a peer that held the request. A peer too old to know the parameters
      reads the request as a plain get and answers at once, which is
      indistinguishable from one reporting a change — except by this. *)
  val answered_header : string
end

module Wire : sig
  (** A key holds ['/'], ['-'] and hex; base64url makes it one safe path
      segment. *)
  val encode_key : string -> string

  val decode_key : string -> (string, [> `Msg of string ]) result

  (** Raises [Failure] on a body that is not a JSON array of entries. *)
  val entries_of_json : string -> Backend.file_entry list

  val entries_to_json : Backend.file_entry list -> string

  (** A batch of bodies in the order the keys were asked for: a four-byte
      big-endian length each, then that many bytes, with an all-ones length for
      a key the store did not hold.

      Framed rather than JSON because a body is bytes. The keys are left out
      because the order is the contract, so a decoder holding the request's keys
      catches a short or reordered answer, which a self-describing body would
      let through as a set of absences. *)
  val bodies_to_string : (Stored_key.t * Bigstring.t option) list -> string

  (** Raises [Failure] on a body that does not frame [keys] exactly. *)
  val bodies_of_string :
    keys:Stored_key.t list -> string -> (Stored_key.t * Bigstring.t option) list
end
