module Make (F : File.S) : sig
  val make :
    fuse_to_key:(string -> string) ->
    open_file:(string -> unit Lwt.t) ->
    close_file:(string -> unit Lwt.t) ->
    fd_for:(string -> Lwt_unix.file_descr option) ->
    Path_ops.t
end
