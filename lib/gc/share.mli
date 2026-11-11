(** Share links (spec 05 §4.11, security §6.1–6.2, 02 §2.14): a public, expiring
    link to one file or folder, its manifest written to the first member that
    serves share links. *)

type created = { url : string; expires : float }

(** [SHARE_DEFAULT_EXPIRY]: 7 days. *)
val default_expiry : float

(** Asks a site share's link once, so its share server publishes it before the
    first visitor (05 §4.11); any failure is logged at debug level. The owner
    runs it in the background after creating one, a run that took ownership
    itself before it exits. *)
val publish : string -> unit

module Make (_ : Tsync_remote.Context.S) : sig
  (** [rel] is a domain path ([""] the whole domain); [expires] seconds from
      now. ABSENT when nothing is at [rel] or a folder is empty; REFUSED when no
      member serves share links or the object is not on the chosen one yet;
      EXISTS when [token] holds another share. [member] is the one to make it
      on, from {!Tsync_config.Config.share_member_name}. [site]: a site share of
      a folder with an index page (http-proxy §A9.9); ABSENT for a file or a
      folder without one. *)
  val create :
    ?expires:float ->
    ?token:string ->
    ?member:string ->
    ?site:bool ->
    string ->
    created

  (** A token or a link; whether a share of this domain was there. Another
      domain's share is left alone. For a site share the link is asked after the
      manifest is deleted, so its share server removes the published copy;
      REFUSED, the share revoked, when it did not answer 404 or 410. *)
  val revoke : string -> bool

  (** A token or a link: makes the share's preview image through the link and
      writes it beside the manifest. ABSENT when no live share of this domain
      holds the token; [`Not_made] says why nothing was written. Blocks for up
      to [SHARE_PREVIEW_TIMEOUT]; the creator runs it after {!create} returned.
  *)
  val preview : string -> [ `Made | `Not_made of string ]

  (** Cached share artifacts on every member: objects and bytes deleted. *)
  val clear_cache : unit -> int * int
end
