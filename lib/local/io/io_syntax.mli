(** The binding operators and the sequential list forms, derived from
    {!Io.S.bind} so a scheduler need not supply them: [open Io_syntax.Make (Io)]
    at the top of a functor over [Io]. *)
module Make (Io : Io.S) : sig
  val ( let* ) : 'a Io.t -> ('a -> 'b Io.t) -> 'b Io.t
  val ( let+ ) : 'a Io.t -> ('a -> 'b) -> 'b Io.t
  val return_unit : unit Io.t
  val return_some : 'a -> 'a option Io.t
  val return_true : bool Io.t
  val return_false : bool Io.t
  val iter_s : ('a -> unit Io.t) -> 'a list -> unit Io.t
  val map_s : ('a -> 'b Io.t) -> 'a list -> 'b list Io.t
  val filter_map_s : ('a -> 'b option Io.t) -> 'a list -> 'b list Io.t
  val fold_left_s : ('a -> 'b -> 'a Io.t) -> 'a -> 'b list -> 'a Io.t
end
