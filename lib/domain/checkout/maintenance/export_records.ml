(** Records of exports nobody came back to finish.

    An export drops its record with the last chunk of the file, so one still
    here is a run that stopped; [cutoff] leaves the ones young enough that
    somebody may yet rerun it, a record costing a few bytes and its loss a whole
    file fetched again. *)

open Sweep

module Over (Io : Io.S) (Files : Fs.S with type 'a io := 'a Io.t) = struct
  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    let run ~cutoff () =
      let dir =
        Cache_layout.exports_dir ~cache_root:C.cache_root C.domain_name
      in
      let* names = Files.readdir_list_quiet dir in
      fold_left_s
        (fun acc name ->
          let path = Filename.concat dir name in
          let* st = Files.stat_opt path in
          match st with
            | Some st when st.Unix.st_mtime <= cutoff ->
                let+ () = Files.unlink_quiet path in
                { files = acc.files + 1; bytes = acc.bytes + st.Unix.st_size }
            | _ -> Io.return acc)
        nothing names
  end
end
