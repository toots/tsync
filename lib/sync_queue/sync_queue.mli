module type S = sig
  val post :
    key:string -> entry_key:Journal.Entry_key.t -> ops:Journal.op list -> unit

  val cancel_put : string -> bool

  (** [true] when no upload is queued or running. *)
  val idle : unit -> bool

  (** Files with an active or queued upload. *)
  val pending : unit -> int

  (** Uploads completed since the daemon started. *)
  val completed_count : unit -> int

  (** Park the workers between uploads. Queued work is kept, so {!pending} keeps
      reporting it, and {!drain} still runs to completion. Not persisted: a
      restart resumes. *)
  val set_paused : bool -> unit

  val paused : unit -> bool

  val start :
    upload:(key:string -> cancel:bool ref -> unit Lwt.t) ->
    on_cursor:(entry_key:Journal.Entry_key.t -> unit) ->
    on_upload_done:(key:string -> unit Lwt.t) ->
    unit

  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S
