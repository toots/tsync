(** The generated passphrase and its spelling (spec extensions/vault §2.1). *)

(** 16 bytes from the operating system's secure generator. *)
val generate : unit -> string

(** Crockford base32, lower case, grouped [5-5-5-5-6]. *)
val to_string : string -> string

(** Normalises the user's input, then decodes it. [None] for anything that is
    not 26 symbols with zero padding bits. *)
val of_string : string -> string option
