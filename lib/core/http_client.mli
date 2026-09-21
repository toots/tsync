(** A pooled HTTP client, shared by whatever speaks HTTP over a link worth
    keeping open.

    Connections are kept and reused per endpoint. A driver that opens one per
    request pays three round trips where one would do and leaves a socket in
    TIME_WAIT for each, which is what caps a catch-up run at a few dozen
    requests a second however fast the link is.

    What is shared is the pool and the vocabulary for reading a response.
    Authentication is not: a caller builds its own headers, since one mints a
    bearer token and another signs the body.

    The sockets are a parameter, so what is here is the pooling policy and the
    reading of a response, and a module that only reads one links neither an
    HTTP implementation nor a scheduler. *)

val code : Cohttp.Response.t -> int
val is_ok : Cohttp.Response.t -> bool

(** A {!Retry.Failed} carrying the status and a bounded excerpt of the body,
    transient for a 5xx or a 429. *)
val failed : string -> int -> string -> exn

(** A bounded, single-line rendering of a response body, for a log. A failing
    proxy answers with a whole HTML page and a store with pretty-printed JSON;
    both come back as one line, cut with a trailing ellipsis. *)
val excerpt : string -> string

(** The sockets themselves: a pool per endpoint, and one request through it.

    Bodies cross as bigstrings rather than in whatever an implementation moves
    them in, so the whole of that vocabulary — and the copy a conversion would
    make — stays on that side. *)
module type POOL = Http_client_intf.POOL

module type S = Http_client_intf.S

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Loop : Retry.LOOP with type 'a io := 'a Io.t)
    (Pool : POOL with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
