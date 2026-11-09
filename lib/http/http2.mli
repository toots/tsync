(** A POST over HTTP/2, which an optional implementation registers when it is
    linked (frontends/http-proxy.md §A4.7). *)

type response = { status : int; body : string }

(** [post ~url ~headers body]. Raises {!Tsync_core.Fail.E} when no answer came.
*)
type post = url:string -> headers:(string * string) list -> string -> response

val register : name:string -> post -> unit

(** The registered implementation, with its name. *)
val implementation : unit -> (string * post) option
