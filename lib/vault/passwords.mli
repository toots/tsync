(** The [passwords] extension's records (spec extensions/passwords §2, §7.1),
    sites (§4), password generation (§5) and CSV import and export (§10.1).
    Pure. *)

(** §4.1: [https://host[:port]], [http://host[:port]] or [android://package]. *)
type site = string

(** §4.1: a site from input, path, query and fragment dropped, an IDN host in
    its A-label form; [Error] is why it is refused. *)
val site_of_string : string -> (site, string) result

(** §4.1: a host label in its A-label form, ASCII lower-cased, non-ASCII by
    Punycode (RFC 3492); [Error] when it cannot be one. *)
val a_label : string -> (string, string) result

(** A site's host, or an [android://] site's package. *)
val host_of : site -> string

(** [d] and each suffix of it at a label boundary, longest first. *)
val suffixes : string -> string list

(** Whether a host or suffix is a public suffix, by the bundled list (§7.3). *)
val is_public_suffix : string -> bool

(** The shortest suffix of a host that is not a public suffix. *)
val registrable : string -> string option

(** §4.2: whether a record's site matches a request's origin or app site: the
    same host, or for a domain name the same registrable domain. *)
val matches : site:site -> origin:string -> bool

(** §2.2: a field beyond a record's fixed keys; a [secret] one is masked where
    shown and copied like a password. [unknown] holds the members this version
    does not know, kept through a rewrite. *)
type field = {
  name : string;
  value : string;
  secret : bool;
  unknown : (string * Yojson.Safe.t) list;
}

type login = {
  title : string;
  urls : site list;
  username : string;
  password : string;
  notes : string;
  totp : string;  (** a TOTP record id or empty *)
  fields : field list;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;  (** kept through a rewrite *)
}

(** §2.1: a record with no site. *)
type note = {
  title : string;
  notes : string;
  fields : field list;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

type passkey = {
  rp_id : string;
  credential_id : string;  (** raw bytes *)
  user_handle : string;  (** raw bytes *)
  user_name : string;
  user_display_name : string;
  algorithm : int;
  private_key : string;  (** raw 32-byte scalar *)
  login : string;  (** a login record id or empty *)
  created : int;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

type t = Login of login | Note of note | Passkey of passkey

(** [Error] is why the plaintext is CORRUPT (§2, §7.1). *)
val of_string : string -> (t, string) result

(** Canonical JSON padded with spaces to a multiple of 256 bytes (§2). *)
val to_string : t -> string

(** The grouped fold's key (§3): the kind with [password], with [title] and
    [notes], or with [credentialId] and [privateKey]. *)
val key_fields : t -> string

(** [modified] of any kind. *)
val modified : t -> int

(** §5: [length] 8 to 128; [Error] when outside. *)
val generate : length:int -> symbols:bool -> (string, string) result

(** §10.1: one parsed row of a CSV export. *)
type row = {
  line : int;  (** of the file, from 1 *)
  title : string;
  urls : site list;
  username : string;
  password : string;
  notes : string;
  otpauth : string;  (** the row's seed URI, or empty *)
}

(** §10.1: [Error] when the file has no password column; otherwise the rows kept
    and, by line, the rows skipped with why. *)
val import_csv : string -> (row list * (int * string) list, string) result

(** §10: [name,url,username,password,note,otpauth], one row per login; [otpauth]
    gives a login's seed URI, or empty. *)
val export_csv : otpauth:(login -> string) -> login list -> string
