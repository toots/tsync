type bigstring = Bigstring.t

external h_string : string -> int -> int -> int64 -> int64 = "tsync_xxh3_string"

external h_bigstring : bigstring -> int -> int -> int64 -> int64
  = "tsync_xxh3_bigstring"

type state

external create : int64 -> state = "tsync_xxh3_create"

external update_string : state -> string -> int -> int -> unit
  = "tsync_xxh3_update_string"

external update_bigstring : state -> bigstring -> int -> int -> unit
  = "tsync_xxh3_update_bigstring"

external digest : state -> int64 = "tsync_xxh3_digest"

let hex16 h = Printf.sprintf "%016Lx" h
let string ?(seed = 0L) s = h_string s 0 (String.length s) seed

let bigstring ?(seed = 0L) ?(off = 0) ?len b =
  let len =
    match len with Some l -> l | None -> Bigarray.Array1.dim b - off
  in
  h_bigstring b off len seed

(* The dual digest of spec 01 §3: both seeds, 16 hex each, joined by '-'. *)
let dual s = hex16 (string ~seed:0L s) ^ "-" ^ hex16 (string ~seed:1L s)

let dual_bigstring ?off ?len b =
  hex16 (bigstring ~seed:0L ?off ?len b)
  ^ "-"
  ^ hex16 (bigstring ~seed:1L ?off ?len b)

type dual_state = state * state

let dual_create () = (create 0L, create 1L)

let dual_update_string (a, b) s off len =
  update_string a s off len;
  update_string b s off len

let dual_update_bigstring (a, b) s off len =
  update_bigstring a s off len;
  update_bigstring b s off len

let dual_digest (a, b) = hex16 (digest a) ^ "-" ^ hex16 (digest b)
