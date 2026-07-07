open Lwt.Syntax

type status = Unreadable | Dirty | Checked of Remote.recheck_report

type summary = {
  checked : int;
  repaired : int;
  unrepairable : int;
  skipped : int;
}

let describe rel = function
  | Unreadable -> Printf.sprintf "SKIP  %s (unreadable sidecar)" rel
  | Dirty -> Printf.sprintf "SKIP  %s (dirty, upload pending)" rel
  | Checked (r : Remote.recheck_report) ->
      if r.chunks_unrepairable > 0 || r.manifest_bad then
        Printf.sprintf "BAD   %s (%d/%d chunks missing%s)" rel
          r.chunks_unrepairable r.chunks_total
          (if r.manifest_bad then ", manifest wrong" else "")
      else if r.chunks_repaired > 0 || r.manifest_repaired || r.local_stale then (
        let parts =
          (if r.chunks_repaired > 0 then
             [
               Printf.sprintf "%d chunk%s re-uploaded" r.chunks_repaired
                 (if r.chunks_repaired = 1 then "" else "s");
             ]
           else [])
          @ (if r.manifest_repaired then ["manifest republished"] else [])
          @ if r.local_stale then ["sidecar updated"] else []
        in
        Printf.sprintf "FIXED %s (%s)" rel (String.concat ", " parts))
      else Printf.sprintf "ok    %s" rel

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)

  let manifest_root = Local.manifest_dir ~cache_root:C.cache_root C.domain_name

  (* Collect every sidecar under the manifest tree; each relative path is a
     file key. *)
  let rec walk rel acc =
    let dir =
      if rel = "" then manifest_root else Filename.concat manifest_root rel
    in
    let* names = Fs_util.readdir_list dir in
    Lwt_list.fold_left_s
      (fun acc name ->
        let r = if rel = "" then name else rel ^ "/" ^ name in
        let* is_dir = Fs_util.is_directory (Filename.concat manifest_root r) in
        if is_dir then walk r acc
        else if Filename.check_suffix name ".tmp" then Lwt.return acc
        else Lwt.return (r :: acc))
      acc names

  let recheck_file rel =
    let key = C.domain_prefix ^ rel in
    let* raw =
      Local.read_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    in
    let state =
      match raw with
        | None -> None
        | Some s -> ( try Some (Manifest.of_string s) with _ -> None)
    in
    match state with
      | None -> Lwt.return Unreadable
      | Some `Dirty -> Lwt.return Dirty
      | Some (`Clean m) ->
          let lp =
            Local.cache_path ~cache_root:C.cache_root ~domain_name:C.domain_name
              ~domain_prefix:C.domain_prefix key
          in
          let* cached = Lwt_unix.file_exists lp in
          if cached then
            let* st = Lwt_unix.stat lp in
            let* manifest_state, report =
              R.recheck_cached ~key ~src_path:lp ~mtime:st.Unix.st_mtime
                ~sidecar:m ()
            in
            let+ () =
              if report.Remote.local_stale then
                Local.write_manifest ~cache_root:C.cache_root
                  ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix key
                  (Manifest.to_string manifest_state)
              else Lwt.return_unit
            in
            Checked report
          else
            let+ report = R.recheck_evicted ~key m in
            Checked report

  (* Recheck every file in the domain, sorted, one at a time (chunk checks
     within a file run concurrently). Returns [None] when the domain has no
     local cache. *)
  let run ~on_file () =
    let* root_ok = Fs_util.is_directory manifest_root in
    if not root_ok then Lwt.return_none
    else
      let* rels = walk "" [] in
      let rels = List.sort compare rels in
      let summary =
        ref { checked = 0; repaired = 0; unrepairable = 0; skipped = 0 }
      in
      let+ () =
        Lwt_list.iter_s
          (fun rel ->
            let+ status = recheck_file rel in
            let s = !summary in
            (summary :=
               match status with
                 | Unreadable | Dirty -> { s with skipped = s.skipped + 1 }
                 | Checked r ->
                     let s = { s with checked = s.checked + 1 } in
                     if r.Remote.chunks_unrepairable > 0 || r.manifest_bad then
                       { s with unrepairable = s.unrepairable + 1 }
                     else if
                       r.chunks_repaired > 0 || r.manifest_repaired
                       || r.local_stale
                     then { s with repaired = s.repaired + 1 }
                     else s);
            on_file ~rel status)
          rels
      in
      Some !summary
end
