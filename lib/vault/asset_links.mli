(** passwords §4.3, pure (the owner fetches): whether the host is a candidate of
    an Android app's package, its registrable domain's labels reversed being a
    prefix of the package name's labels ([github.com] for [com.github.android],
    [www.instagram.com] for [com.instagram.android]). *)
val candidate : package:string -> string -> bool

(** Whether an [assetlinks.json] body grants
    [delegate_permission/common.get_login_creds] to [package] signed with one of
    [certs], SHA-256 fingerprints in any case, with or without colons. A body
    that does not parse grants nothing. *)
val grants : package:string -> certs:string list -> string -> bool
