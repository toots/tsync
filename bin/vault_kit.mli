(** Writes the emergency kit of a domain's vault (vault §3.1) at [path]: one
    self-contained HTML page holding the secret key as text and as a QR code,
    created with mode 0600. INVALID when [path] exists, which is never replaced.
*)
val write : path:string -> domain:string -> secret_key:string -> unit
