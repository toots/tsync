open Lwt.Syntax

type status = Unreadable | Staged | Checked of Remote.recheck_report

type summary = {
  checked : int;
  repaired : int;
  unrepairable : int;
  skipped : int;
}

let describe rel = function
  | Unreadable -> Printf.sprintf "SKIP  %s (unreadable sidecar)" rel
  | Staged -> Printf.sprintf "SKIP  %s (unsynced edits)" rel
  | Checked (r : Remote.recheck_report) ->
      if r.chunks_unrepairable > 0 || r.manifest_bad then
        Printf.sprintf "BAD   %s (%d/%d chunks missing%s)" rel
          r.chunks_unrepairable r.chunks_total
          (if r.manifest_bad then ", manifest wrong" else "")
      else if r.chunks_repaired > 0 || r.manifest_repaired then (
        let parts =
          (if r.chunks_repaired > 0 then
             [
               Printf.sprintf "%d chunk%s re-uploaded" r.chunks_repaired
                 (if r.chunks_repaired = 1 then "" else "s");
             ]
           else [])
          @ if r.manifest_repaired then ["manifest republished"] else []
        in
        Printf.sprintf "FIXED %s (%s)" rel (String.concat ", " parts))
      else Printf.sprintf "ok    %s" rel

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)
  module Mf = Manifest.Make (C)
  module Cc = Chunk_cache.Make (C) (R)

  (* The local half of a recheck: every member segment of every cache chunk must
     hash to the key it was published under. Manifest-driven, unlike the rest of
     the store's bookkeeping — a cache chunk holds several stored chunks, so its
     body cannot be checked against its own name and the manifests are what say
     which keys belong in it. Returns (checked, dropped); a dropped body
     re-downloads on the next read. *)
  let verify_chunk_cache () =
    let* rels = Mf.walk () in
    Lwt_list.fold_left_s
      (fun acc rel ->
        let* state = Mf.read (C.domain_prefix ^ rel) in
        match state with
          | Some (`Clean m) ->
              Lwt_list.fold_left_s
                (fun (checked, dropped) group ->
                  let* present = Cc.exists group in
                  if not present then Lwt.return (checked, dropped)
                  else
                    let+ ok = Cc.verify_group ~group in
                    (checked + 1, if ok then dropped else dropped + 1))
                acc (Mf.groups m)
          | Some `Dirty | None -> Lwt.return acc)
      (0, 0) rels

  (* Verification is manifest-driven: every chunk a file names must be intact on
     the backend. Local bytes are checked separately and wholesale by
     {!Chunk_cache.verify_group} — content addressing makes that a stronger check than
     re-hashing one file's copy, and there is no assembled file to re-hash. *)
  let recheck_file rel =
    let key = C.domain_prefix ^ rel in
    let* staged = Mf.staged_exists key in
    if staged then Lwt.return Staged
    else
      let* state = Mf.read key in
      match state with
        | None | Some `Dirty -> Lwt.return Unreadable
        | Some (`Clean m) ->
            let local_body (entry : Manifest.chunk_entry) =
              let index = entry.Manifest.index in
              match Mf.group_at m index with
                | Some group -> Cc.member_if_local ~group ~index
                | None -> Lwt.return_none
            in
            let+ report = R.recheck_from_manifest ~key ~local_body m in
            Checked report

  (* Recheck every file in the domain, sorted, one at a time (chunk checks
     within a file run concurrently). Returns [None] when the domain has no
     local cache. *)
  let run ~on_file () =
    let* root_ok = Mf.mirror_exists () in
    if not root_ok then Lwt.return_none
    else
      let* rels = Mf.walk () in
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
                 | Unreadable | Staged -> { s with skipped = s.skipped + 1 }
                 | Checked r ->
                     let s = { s with checked = s.checked + 1 } in
                     if r.Remote.chunks_unrepairable > 0 || r.manifest_bad then
                       { s with unrepairable = s.unrepairable + 1 }
                     else if r.chunks_repaired > 0 || r.manifest_repaired then
                       { s with repaired = s.repaired + 1 }
                     else s);
            on_file ~rel status)
          rels
      in
      Some !summary
end
