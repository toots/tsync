open Lwt.Syntax

type answer = { store : string; queued : int option }

(* A store whose requests are not draining is not a store that is slow: nothing
   is consuming them, which is what an undeployed or misfiltered notification
   looks like from here. *)
let poll_interval = 3.
let stall_after = 5

let unhealthy (r : Corruption.report) =
  r.Corruption.entries <> []
  || r.Corruption.unverified <> []
  || r.Corruption.unreachable <> []

module Make (C : Conf_lwt.S) = struct
  module L = Chunk_layout.Make (C)

  let follow ~on_progress ~on_done ~on_stalled
      (m : (module Backend_lwt.Store) Backend.member) =
    let (module B : Backend_lwt.Store) = m.Backend.backend in
    let jobs = L.verify_jobs_prefix in
    let corrupted = L.corrupted_prefix in
    (* A listing that fails counts as nothing found rather than ending the
       watch: the store is being asked about work it may not have started. *)
    let count prefix =
      Lwt.catch
        (fun () ->
          let+ es = B.list_prefix ~prefix () in
          List.length es)
        (fun _ -> Lwt.return 0)
    in
    let store = m.Backend.name in
    let rec loop stalled last =
      let* left = count jobs in
      let* found = count corrupted in
      on_progress ~store ~left ~found;
      if left = 0 then begin
        on_done ~store ~found;
        Lwt.return_unit
      end
      else (
        let stalled = if left = last then stalled + 1 else 0 in
        if stalled >= stall_after then begin
          on_stalled ~store;
          Lwt.return_unit
        end
        else
          let* () = Lwt_unix.sleep poll_interval in
          loop stalled left)
    in
    loop 0 (-1)

  let verify ~on_answers ~on_progress ~on_done ~on_stalled () =
    let* answers =
      Lwt_list.map_s
        (fun (m : (module Backend_lwt.Store) Backend.member) ->
          let (module B : Backend_lwt.Store) = m.Backend.backend in
          let+ a = B.verify_all ~chunk_prefix:C.chunk_prefix () in
          match a with
            | `Queued n -> { store = m.Backend.name; queued = Some n }
            | `Unsupported -> { store = m.Backend.name; queued = None })
        C.members
    in
    on_answers answers;
    let queued =
      List.filter_map
        (fun a -> Option.map (fun n -> (a.store, n)) a.queued)
        answers
    in
    if queued = [] then Lwt.return `Nothing_queued
    else
      let+ () =
        Lwt_list.iter_p
          (fun (m : (module Backend_lwt.Store) Backend.member) ->
            if List.mem_assoc m.Backend.name queued then
              follow ~on_progress ~on_done ~on_stalled m
            else Lwt.return_unit)
          C.members
      in
      `Watched
end
