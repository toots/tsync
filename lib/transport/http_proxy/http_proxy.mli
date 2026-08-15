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
    body:Chunk.t ->
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
    body:Chunk.t ->
    bool
end

module Wire : sig
  (** A key holds ['/'], ['-'] and hex; base64url makes it one safe path
      segment. *)
  val encode_key : string -> string

  val decode_key : string -> (string, [> `Msg of string ]) result

  (** Raises [Failure] on a body that is not a JSON array of entries. *)
  val entries_of_json : string -> Backend.file_entry list

  val entries_to_json : Backend.file_entry list -> string
end
