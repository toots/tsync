module Make (F : File.S) : sig
  val make :
    fuse_to_key:(string -> string) ->
    open_file:(string -> unit) ->
    close_file:(string -> unit Lwt.t) ->
    Path_ops.t
end
