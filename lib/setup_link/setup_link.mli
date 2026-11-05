(** Setup links (spec algorithms/setup-link.md). A creator calls {!create} and
    writes {!stored_to_string} at the token's share key; a listener reads it
    back with {!stored_of_string} to serve the page; a joiner calls
    {!link_of_string}, {!fetch}, then {!open_}. *)

open Tsync_core

(** An [http-proxy] backend, the only kind a link carries (§3). *)
type backend = { name : string; url : string; secret : string }

type domain = { name : Domain_name.t; backends : backend list }

(** A payload domain this reader can hold, or the reason it cannot. *)
type entry =
  | Joinable of domain
  | Unusable of { name : string; reason : string }

type payload = { from : string; entries : entry list }

(** A vault's appearance (vault §8.1); [icon] is PNG bytes. *)
type vault_look = { color : string; icon : string option }

type about = {
  name : Domain_name.t;
  extensions : string list;
  vault : vault_look option;
}

(** [key] is the 32 raw bytes of the fragment. *)
type link = { base : string; token : string; key : string }

(** The manifest at [tsync/shares/<token>] (§4); [sealed] is raw bytes. *)
type stored = {
  domain : Domain_name.t;
  expires : float;
  sealed : string;
  about : about list;
}

val default_expiry : float
val max_domains : int
val link_to_string : link -> string

(** [Error] is the sentence for the person who pasted it. *)
val link_of_string : string -> (link, string) result

(** [expires] is absolute; [domains] is not empty, and its first one names the
    manifest. *)
val create :
  base:string ->
  expires:float ->
  from:string ->
  about:about list ->
  domain list ->
  link * stored

val stored_to_string : stored -> string

(** [Error] for a body that is not a valid setup manifest, a share of another
    type included. *)
val stored_of_string : string -> (stored, string) result

(** [GET <base>/join/<token>?json=1]; [Error] for a revoked, expired or damaged
    link. Raises the transport's failures. *)
val fetch : link -> (stored, string) result

val open_ : link -> stored -> (payload, string) result
