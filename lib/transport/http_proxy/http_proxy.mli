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

  (** {1 A listing, a page per line}

      So that neither end holds a whole namespace to write or parse it. The last
      line is {!done_line}: a chunked body that stops early looks exactly like
      one that finished, and a source listing cut short is objects a resync
      never copies and never reports, so a reader checks for the terminator
      rather than trusting end-of-body.

      Both ends must be of a version, as for {!Backend.S.put_if_absent}: a
      client too old to know the framing fails on the terminator line, and a
      client too new fails on its absence. Neither reads as success. *)

  val page_line : Backend.file_entry list -> string
  val done_line : string
  val error_line : string -> string

  (** Raises [Failure] on a line that is none of the three. *)
  val parse_line :
    string -> [ `Page of Backend.file_entry list | `Done | `Error of string ]

  (** Reassembly, which belongs with the framing rather than with whoever reads:
      a body arrives in whatever pieces the network chose, and a page split
      across two of them is the ordinary case rather than the odd one. *)
  type reader

  val reader : unit -> reader

  (** The complete lines in [chunk] together with what earlier feeds left over;
      an incomplete trailing line is kept for the next call. *)
  val feed : reader -> string -> string list

  (** What is still buffered, which after the last chunk of a well-formed stream
      is nothing. *)
  val rest : reader -> string
end
