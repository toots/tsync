(** passwords §4.3: the sites an Android app is verified for, as this owner last
    learned them. [verified] answers at once from verdicts kept for 24 hours,
    and starts a background fetch for each candidate host it has none for, so a
    newly verified site is offered from the next request on. *)
val verified : package:string -> certs:string list -> string list -> string list

(** The fetch of [https://<host>/.well-known/assetlinks.json]: the body of a 200
    of at most 256 KiB within 5 s, else [None]. A test replaces it. *)
val fetch : (string -> string option) Atomic.t

(** Forgets every verdict; for tests. *)
val reset : unit -> unit
