(** The engine of one domain in its owner (spec 04 §3–4, 03, wal-and-journal,
    conflict-resolution): the file operations frontends call, the upload and
    metadata queues that publish them, and the journal passes that apply peers'
    changes.

    Every operation on names takes the domain's metadata lock and every content
    change its key's lock, so a frontend's edit and a peer's change meet under
    one lock. No lock is held across a store request. *)

type bridge = Outbound.bridge = Incremental | Hold of string

module type S = Engine_intf.S

(** The pause flag of 07 §2.6: present means paused. *)
val pause_flag : data_dir:string -> Tsync_core.Domain_name.t -> string

module Make (_ : Engine_ctx.S) : S
