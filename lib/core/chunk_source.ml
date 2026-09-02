type 'a t =
  | Stored of string
  | Mapped of (unit -> Bigstring.t)
  | Filled of { len : int; fill : Bigstring.t -> 'a }
