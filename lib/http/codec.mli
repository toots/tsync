(** HTTP/1.1 framing shared by the client and the server: a buffered reader,
    header blocks, and bodies by length, by chunks or to end of stream. *)

(** Lower-case names, in received order. *)
type headers = (string * string) list

val header : headers -> string -> string option

exception Malformed of string

(** A block or body past its bound. *)
exception Too_large

type reader

(** [progress] is called for every piece received. *)
val reader : ?progress:(unit -> unit) -> Transport.t -> reader

(** Whether bytes are buffered past the last read. *)
val buffered : reader -> bool

(** The first line and the header lines of a block, within [limit] bytes; [None]
    at end of stream before any byte. *)
val read_head :
  ?timeout:float -> limit:int -> reader -> (string * headers) option

(** A body of [length] bytes, of chunks, or to end of stream, within [limit]. *)
val read_body :
  ?timeout:float ->
  limit:int ->
  reader ->
  [ `Length of int | `Chunked | `Eof ] ->
  Tsync_core.Bigstring.t

(** How a message with these headers delimits its body. *)
val framing : headers -> [ `Length of int | `Chunked | `Eof ]

val write_head : Buffer.t -> string -> headers -> unit
