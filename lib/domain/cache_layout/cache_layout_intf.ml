module type FS = sig
  include Fs.S

  val record_dir_name : string -> string -> unit io
  val real_dir_name : string -> string -> string io
end

module type S = sig
  type 'a io

  (** Record what a directory stored under a handle is really called, unless it
      is already recorded. Both trees that mirror real paths keep these. *)
  val record_dir_name : string -> string -> unit io

  (** [real_dir_name dir_path name] is [name] itself, or what the marker in
      [dir_path] records when [name] is a handle. *)
  val real_dir_name : string -> string -> string io

  (** What a resync starts without: the scratch space. The mirror, the folder
      index and the chunks stay; the walk rewrites the first two in place, and
      staged edits are kept since nothing else holds those bytes. The applied
      entries stay as well: the rebuild is reported there. *)
  val clear_projection : cache_root:string -> domain_name:string -> unit io

  (** Drop every folder record last written before [cutoff]: what a walk that
      rewrote everything the store still has did not touch. The mirror's own
      sweep is {!Checkout.S.sweep_stale}, which reports what it drops. Only
      after a walk that reached everything, a folder it could not read being not
      one that is gone. *)
  val sweep_stale :
    cutoff:float -> cache_root:string -> domain_name:string -> unit io
end
