module type S = sig
  val post :
    key:string ->
    src_path:string ->
    entry_key:string ->
    ops:Journal.op list ->
    unit

  val cancel_put : string -> bool

  (** [true] when no upload is queued or running. *)
  val idle : unit -> bool

  val start :
    upload:(key:string -> cancel:bool Atomic.t -> unit) ->
    on_version:(entry_key:string -> unit) ->
    on_upload_done:(key:string -> unit) ->
    unit

  val drain : unit -> unit
end

module Make (C : Conf.S) : S
