val send : socket_path:string -> string -> string

(** [fields] as one request, answering its reply object. Raises [Failure]
    carrying the daemon's own message when the reply says [ok:false].

    The half that reads what {!Ipc_handler.error_reply} writes, so a caller acts
    on the envelope rather than on the wording of a sentence. [socket_path] is
    required rather than defaulted: a socket belongs to a domain, and which
    domain a caller means is the caller's to decide. *)
val request :
  socket_path:string ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list

(** {!request} for the shape every action uses. The optional fields are omitted
    rather than sent empty, an absent [domain] being how a caller addresses a
    daemon serving exactly one. *)
val action :
  socket_path:string ->
  ?item:Item_ref.t ->
  ?arg:string ->
  ?domain:string ->
  string ->
  (string * Yojson.Safe.t) list
