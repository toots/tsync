module type Storable = sig
  type t

  (** [of_string] must invert this, and this must be injective: two keys are one
      key here when their bytes agree, which is what stands in for
      {!Stdlib.Hashtbl}'s structural equality. *)
  val to_string : t -> string

  val of_string : string -> t
end

module type S = sig
  type key
  type value
  type t

  (** Sized for [n] bindings and grown as needed, as {!Stdlib.Hashtbl.create}
      is. The mapping is made under [Filename.get_temp_dir_name ()]. *)
  val create : int -> t

  val replace : t -> key -> value -> unit

  (** Raises [Not_found] where {!find_opt} answers [None]. *)
  val find : t -> key -> value

  val find_opt : t -> key -> value option
  val mem : t -> key -> bool
  val length : t -> int

  (** In an unspecified order, as {!Stdlib.Hashtbl.iter} is; binding a key from
      [f] is undefined. *)
  val iter : (key -> value -> unit) -> t -> unit

  val fold : (key -> value -> 'a -> 'a) -> t -> 'a -> 'a
end
