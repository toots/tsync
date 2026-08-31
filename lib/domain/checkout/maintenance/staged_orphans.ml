(** Staged bodies no sidecar names, and the empty directories left behind.

    A body is named by uuid and referenced only from a staged manifest, so one
    no manifest names is unreachable by construction -- except while it is being
    made, {!Staged_body.stage_slot} creating the body before the manifest that
    records it.

    [cutoff] is what tells those two apart, and it is why this needs neither a
    lock nor a machine with nothing serving on it: a body younger than the
    cutoff may be one some process is still assembling, so it is left, and one
    older than it is a leftover whoever wrote it. *)

open Sweep

module type FILES = sig
  type 'a io

  val is_directory : string -> bool io
  val readdir_list : string -> string list io
  val reap_older_than : cutoff:float -> string -> bool io
  val stat_opt : string -> Unix.stats option io
  val unlink_quiet : string -> unit io
end

(** The staged tree, for the one question this asks of it: which bodies are
    still named. *)
module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val root : unit -> string
    val uuids : unit -> string list io
  end
end

module Over
    (Io : Io.S)
    (Files : FILES with type 'a io := 'a Io.t)
    (Staged : STAGED with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest -> Io.bind (f acc x) (fun acc -> fold_left_s f acc rest)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Sm = Staged.Make (C)

    (* Cutoff 0 deletes no file, only prunes what is left empty. *)
    let prune_dirs () =
      let+ (_ : bool) = Files.reap_older_than ~cutoff:0. (Sm.root ()) in
      ()

    let run ~cutoff () =
      let* uuids = Sm.uuids () in
      let live = Hashtbl.create (List.length uuids) in
      List.iter (fun uuid -> Hashtbl.replace live uuid ()) uuids;
      let sweep acc dir =
        let* here = Files.is_directory dir in
        if not here then Io.return acc
        else
          let* names = Files.readdir_list dir in
          fold_left_s
            (fun acc name ->
              if Hashtbl.mem live name then Io.return acc
              else (
                let path = Filename.concat dir name in
                let* st = Files.stat_opt path in
                match st with
                  | Some st when st.Unix.st_mtime <= cutoff ->
                      Log.info "reclaiming orphaned staged body %s" name;
                      let+ () = Files.unlink_quiet path in
                      {
                        files = acc.files + 1;
                        bytes = acc.bytes + st.Unix.st_size;
                      }
                  | _ -> Io.return acc))
            acc names
      in
      let* acc =
        sweep nothing
          (Cache_layout.staged_chunks_dir ~cache_root:C.cache_root C.domain_name)
      in
      let* acc =
        sweep acc
          (Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name)
      in
      let+ () = prune_dirs () in
      acc
  end
end
