(** Temp files a crashed writer left in the manifest mirror.

    {!Filename.with_temp_rename} writes beside its target and renames; a process
    that dies in between leaves the temp file. Nothing reads one, and every
    listing already skips it ({!Stored_key.internal_leaf}), so what this
    reclaims is disk and nothing else. *)

open Sweep

(* The filesystem calls a sweep of the mirror makes, spelled as {!Fs} spells
   them so one can be handed over as it stands. *)

module Over
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Bounded : Bounded.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* One stat per entry is what a sweep of the mirror costs, and a mirror holds
     hundreds of thousands of them: taken one at a time that is minutes of round
     trips for seconds of work.

     Leaf level only. The recursion descends outside the pool, so a directory
     never holds a slot while waiting for its children -- one pool nested inside
     itself deadlocks. *)
  let stat_slots = Bounded.create ~max:64 ()

  (* A temp name carries the pid that wrote it ({!Filename.temp_path}), so what
     a crash left behind is told apart from what a live process is still writing
     by asking after the owner. The same test {!Spool.reap} makes, and what lets
     this run against a domain that is being served rather than only before
     anything forks. *)
  let orphaned name =
    match Filename.temp_owner name with
      | Some pid -> not (Tsync_io.Fs.pid_alive pid)
      | None -> false

  (* Missing paths are ordinary here: the mirror is written by other processes
     while this walks it, so an entry that vanishes is skipped rather than
     ending the sweep -- unwinding leaves everything after it uncollected. *)
  let under root =
    let rec walk dir acc =
      let* names = Files.readdir_list_quiet dir in
      let* entries =
        Bounded.map_with stat_slots
          (fun name ->
            let path = Filename.concat dir name in
            let+ st = Files.stat_opt path in
            (name, path, st))
          names
      in
      let* acc =
        fold_left_s
          (fun acc (name, path, st) ->
            match st with
              | Some st when st.Unix.st_kind <> Unix.S_DIR && orphaned name ->
                  let+ () = Files.unlink_quiet path in
                  { files = acc.files + 1; bytes = acc.bytes + st.Unix.st_size }
              | _ -> Io.return acc)
          acc entries
      in
      fold_left_s
        (fun acc (_, path, st) ->
          match st with
            | Some { Unix.st_kind = Unix.S_DIR; _ } -> walk path acc
            | _ -> Io.return acc)
        acc entries
    in
    let* here = Files.is_directory root in
    if here then walk root nothing else Io.return nothing

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    let run () =
      under (Cache_layout.manifests_dir ~cache_root:C.cache_root C.domain_name)
  end
end
