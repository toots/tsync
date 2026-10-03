(** Local IPC (spec 01 §11, 07 §4, security-model §7): one JSON object per line
    over a Unix stream socket, requests and replies alternating, any number of
    requests per connection. *)

type json = Yojson.Safe.t

val max_line : int
val line_deadline : float
val max_connections : int
val subscriber_backlog : int

(** failure-model §8.3. *)
val request_deadline : float

val client_deadline : float
val advisory_deadline : float

(** [{"ok":true, …fields}]. *)
val ok : (string * json) list -> json

(** [{"ok":false,"code","error"}], with [retryAfter] when the failure has one.
*)
val failure : Tsync_core.Fail.t -> json

(** A request's string field. *)
val field : json -> string -> string option

(** {1 Server} *)

type answer =
  | Reply of json
  | Subscribe of string * json * json list
      (** the topic, the reply, and the first events queued once the connection
          carries the topic's events *)
  | Stream of ((json -> unit) -> json)
      (** run with a sender of lines, each an object with a [stream] field, then
          the reply; the connection serves further requests *)

type server

(** Binds [path] after checking its directory (0700, owned by this uid) and its
    length, removing a stale socket file, and serves until {!close}. Each
    connection's peer must be this uid. A failure while serving one connection
    closes that connection only. *)
val serve : path:string -> (json -> answer) -> server

(** Stops accepting, ends every connection, removes the socket file once. A
    connection answering a request is given a few seconds to write its reply. *)
val close : server -> unit

(** The number of subscribers of [topic] the event was queued for. A
    subscriber's backlog is bounded; on overflow its oldest events are dropped.
*)
val publish : server -> string -> json -> int

(** How many connections are subscribed to [topic] now. *)
val subscribers : server -> string -> int

(** {1 Client} *)

(** Nothing accepts connections at the path. *)
exception Not_serving of string

module Client : sig
  type t

  (** Connects within [timeout] (default 5 s); DEADLINE when the server's
      backlog stays full, {!Not_serving} when nothing listens. *)
  val connect : ?timeout:float -> string -> t

  (** Sends one request and reads its reply within [timeout] (default
      {!client_deadline}); DEADLINE otherwise. *)
  val request : ?timeout:float -> t -> json -> json

  (** The next event line of a subscription. [None] at end of stream. *)
  val next : ?timeout:float -> t -> json option

  val close : t -> unit
end

(** One request on its own connection. *)
val call : ?timeout:float -> string -> json -> json

(** A bulk request (07 §4.3): no total deadline; abandoned when a [ping] on a
    separate connection misses its deadline. *)
val call_bulk : string -> json -> json

(** {!call_bulk} for a {!Stream} answer: each streamed line goes to [on_line]
    before the reply. *)
val call_stream : string -> json -> on_line:(json -> unit) -> json

(** Never fails its caller: failures are logged once per path and kind. *)
val advisory : string -> json -> unit
