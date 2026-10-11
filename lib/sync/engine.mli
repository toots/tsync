(** The engine of one domain in its owner (spec 04 §3–4, 03, publication,
    conflict-resolution): the file operations frontends call, the upload queue
    that sends their content, and the cycle that merges the main's entries and
    commits this client's changes.

    Every operation on names takes the domain's metadata lock and every content
    change its key's lock, so a frontend's edit and a merge meet under one lock.
    No store request is made under the metadata lock. *)

module type S = Engine_intf.S

(** The pause flag of 07 §2.6: present means paused. *)
val pause_flag : data_dir:string -> Tsync_core.Domain_name.t -> string

module Make (_ : Engine_ctx.S) : S
