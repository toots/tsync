type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

val read : string -> buffer -> offset:int64 -> int
val write : string -> buffer -> offset:int64 -> int
