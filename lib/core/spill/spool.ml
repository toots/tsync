(** The buffered writer nothing here can supply: a channel is state, and the
    stream-to-stream copy in {!Make.append_file} is not a sequence of reads and
    writes this could spell for itself. *)
module type APPEND = sig
  type 'a io
  type t

  val open_out : string -> t io
  val write : t -> string -> unit io

  (** Append the whole of [src], which must already be flushed. *)
  val write_file : t -> src:string -> unit io

  val close : t -> unit io
end

(** The four calls a spool makes of a filesystem, spelled as {!Fs} spells them
    so that one can be handed over as it stands. *)
module type FILES = sig
  type 'a io

  val mkdir_p : string -> unit io
  val unlink_quiet : string -> unit io
  val readdir_list_quiet : string -> string list io
  val stat_opt : string -> Unix.stats option io
end

module Make
    (Io : Io.S)
    (Files : FILES with type 'a io := 'a Io.t)
    (Append : APPEND with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  type t = { path : string; out : Append.t }

  let create ~dir ~name =
    let* () = Files.mkdir_p dir in
    let path = Filename.temp_path (Filename.concat dir name) in
    let+ out = Append.open_out path in
    { path; out }

  let path t = t.path
  let append t s = Append.write t.out s
  let close t = Append.close t.out
  let append_file t ~src = Append.write_file t.out ~src

  let close_quiet t =
    Io.catch (fun () -> Append.close t.out) (fun _ -> Io.return ())

  let seal t =
    let* () = Append.close t.out in
    (* Nothing here can recover the ops the file held; what naming it buys is a
       caller that fails saying which spool went missing, rather than an
       uncaught [ENOENT] from a stat with no context. *)
    let* st = Files.stat_opt t.path in
    match st with
      | None ->
          Io.fail
            (Failure
               (Printf.sprintf "spool %s vanished before it was read" t.path))
      | Some st ->
          Io.return
            (Bigstring.map_file ~path:t.path ~offset:0 ~len:st.Unix.st_size)

  let drop t =
    let* () = close_quiet t in
    Files.unlink_quiet t.path

  (* Only what a dead process left: a concurrent run's spool is live, and
     deleting it takes its ops with it and crashes it at seal. *)
  let reap ~dir =
    let* names = Files.readdir_list_quiet dir in
    let rec go = function
      | [] -> Io.return ()
      | name :: rest ->
          let* () =
            match Filename.temp_owner name with
              | Some pid when not (Tsync_io.Fs.pid_alive pid) ->
                  Files.unlink_quiet (Filename.concat dir name)
              | _ -> Io.return ()
          in
          go rest
    in
    go names
end
