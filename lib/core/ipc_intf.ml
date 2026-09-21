module type TRANSPORT = sig
  type 'a io
  type input
  type output
  type server

  val connect : string -> (input * output) io

  (** Raises at end of input. That is how a client going away reaches the loops
      inside: both of them read until this stops answering. *)
  val read_line : input -> string io

  val write_line : output -> string -> unit io
  val flush : output -> unit io
  val close : input -> unit io
  val serve : path:string -> (input * output -> unit io) -> server io
  val shutdown : server -> unit io
end
