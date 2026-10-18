(** The [totp] extension's record (spec extensions/totp §2), its codes (§4) and
    its [otpauth] URIs (§5.1). *)

type algorithm = [ `SHA1 | `SHA256 | `SHA512 ]

type t = {
  issuer : string;
  account : string;
  secret : string;  (** base32, upper case, no padding *)
  algorithm : algorithm;
  digits : int;
  period : int;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;  (** kept through a rewrite *)
}

(** [Error] is why the plaintext is CORRUPT. *)
val of_string : string -> (t, string) result

val to_string : t -> string

(** The code fields joined: the key of the grouped fold (§3). *)
val code_fields : t -> string

(** The code at a wall-clock second, zero-padded. *)
val code_at : t -> unix_time:int64 -> string

val seconds_left : t -> unix_time:int64 -> int

(** [modified] is [now]; [Error] is why the URI is refused. *)
val of_uri : now:int -> string -> (t, string) result

(** §5.3: SHA1, 6 digits, 30 s; the secret may carry spaces. *)
val of_secret :
  now:int -> issuer:string -> account:string -> string -> (t, string) result

val to_uri : t -> string

(** RFC 4648 base32, upper case, no padding. *)
val base32_encode : string -> string
