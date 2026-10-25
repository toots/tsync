(** Writes a kit of a domain's vault at [path]: one self-contained HTML page
    holding the key as text and as a QR code, created with mode 0600; the
    emergency kit's secret key (vault §3.1) or the backup key's seed and id
    (§8.3). INVALID when [path] exists, which is never replaced. *)
val write :
  path:string ->
  domain:string ->
  [ `Emergency of string | `Backup of string * string ] ->
  unit
