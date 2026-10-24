(** Generated passphrases (vault §2.3), drawn uniformly from the CSPRNG out of
    the EFF large word list bundled with tsync, less its four hyphenated words:
    [count] is 7772, about 12.9 bits a word. *)
val count : int

(** [n] words joined by [-], in lower case. *)
val passphrase : int -> string
