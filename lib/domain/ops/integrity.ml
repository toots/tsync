type answer = { store : string; queued : int option }
type repair = Repaired of { from_store : string } | Cleared | Unrepairable

type repair_stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  lost : string list;
}

let no_repairs =
  { checked = 0; repaired = 0; cleared = 0; unrepairable = 0; lost = [] }

let describe_repair ~chunk_key ~store = function
  | Repaired { from_store } ->
      Printf.sprintf "FIXED %s on %s (from %s)" chunk_key store from_store
  | Cleared ->
      Printf.sprintf "STALE %s on %s (body was already correct)" chunk_key store
  | Unrepairable ->
      Printf.sprintf "LOST  %s on %s (no store holds these bytes)" chunk_key
        store

(* A store whose requests are not draining is not a store that is slow: nothing
   is consuming them, which is what an undeployed or misfiltered notification
   looks like from here. *)
let poll_interval = 3.
let stall_after = 5

let unhealthy (r : Corruption.report) =
  r.Corruption.entries <> []
  || r.Corruption.unverified <> []
  || r.Corruption.unreachable <> []

module Over
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Markers : Corruption.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let iter_p f xs = Io.iter_p f xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Cor = Markers.Make (C)
    module L = Chunk_layout.Make (C)

    let follow ~on_progress ~on_done ~on_stalled
        (m : (module C.Store) Backend.member) =
      let (module B : C.Store) = m.Backend.backend in
      let jobs = L.verify_jobs_prefix in
      let corrupted = L.corrupted_prefix in
      (* A listing that fails counts as nothing found rather than ending the
         watch: the store is being asked about work it may not have started. *)
      let count prefix =
        Io.catch
          (fun () ->
            let+ es = B.list_prefix ~prefix () in
            List.length es)
          (fun _ -> Io.return 0)
      in
      let store = m.Backend.name in
      let rec loop stalled last =
        let* left = count jobs in
        let* found = count corrupted in
        on_progress ~store ~left ~found;
        if left = 0 then begin
          on_done ~store ~found;
          Io.return ()
        end
        else (
          let stalled = if left = last then stalled + 1 else 0 in
          if stalled >= stall_after then begin
            on_stalled ~store;
            Io.return ()
          end
          else
            let* () = Clock.sleep poll_interval in
            loop stalled left)
      in
      loop 0 (-1)

    let verify ~on_answers ~on_progress ~on_done ~on_stalled () =
      let* answers =
        map_s
          (fun (m : (module C.Store) Backend.member) ->
            let (module B : C.Store) = m.Backend.backend in
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
      if queued = [] then Io.return `Nothing_queued
      else
        let+ () =
          iter_p
            (fun (m : (module C.Store) Backend.member) ->
              if List.mem_assoc m.Backend.name queued then
                follow ~on_progress ~on_done ~on_stalled m
              else Io.return ())
            C.members
        in
        `Watched

    let good_body (module B : C.Store) chunk_key =
      Io.catch
        (fun () ->
          let+ body = B.get_opt ~key:(L.key chunk_key) () in
          match body with
            | Some body when Chunks.key_of_body body = chunk_key -> Some body
            | _ -> None)
        (fun _ -> Io.return None)

    let member_named name =
      List.find_opt
        (fun (m : (module C.Store) Backend.member) -> m.Backend.name = name)
        C.members

    (* A backfill target is excluded by [readable]: it is not read from, and may
       not hold the chunk at all. *)
    let sources_for ~source ~bad_store =
      List.filter
        (fun (m : (module C.Store) Backend.member) ->
          m.Backend.name <> bad_store
          && m.Backend.readable
          && match source with None -> true | Some n -> m.Backend.name = n)
        C.members

    let rec first_good chunk_key = function
      | [] -> Io.return None
      | (m : (module C.Store) Backend.member) :: rest -> (
          let* body = good_body m.Backend.backend chunk_key in
          match body with
            | Some body -> return_some (m.Backend.name, body)
            | None -> first_good chunk_key rest)

    (* A stale marker is repaired by rewriting the body over itself rather than by
       removing the marker: the store has to be the one to conclude the object is
       fine — see the .mli. *)
    let repair_one ~source ~dry_run (e : Corruption.entry) =
      let chunk_key = e.Corruption.chunk_key in
      match member_named e.Corruption.store with
        | None -> Io.return Unrepairable
        | Some m -> (
            let (module Dst : C.Store) = m.Backend.backend in
            let write body =
              if dry_run then Io.return ()
              else Dst.put ~key:(L.key chunk_key) ~data:body ()
            in
            (* Its own copy first: see {!Cleared}. *)
            let* mine = good_body m.Backend.backend chunk_key in
            match mine with
              | Some body ->
                  let+ () = write body in
                  Cleared
              | None -> (
                  let* found =
                    first_good chunk_key
                      (sources_for ~source ~bad_store:e.Corruption.store)
                  in
                  match found with
                    | None -> Io.return Unrepairable
                    | Some (from_store, body) ->
                        let+ () = write body in
                        Repaired { from_store }))

    let repair ?source ?(dry_run = false) ?(on_start = fun ~total:_ -> ())
        ?(on_chunk = fun ~done_:_ ~total:_ ~chunk_key:_ ~store:_ _ -> ()) () =
      if C.read_only && not dry_run then
        failwith
          (Printf.sprintf "%s is read-only, so nothing here may be rewritten."
             C.domain_name);
      let* report = Cor.list () in
      let total = List.length report.Corruption.entries in
      on_start ~total;
      let* stats =
        fold_left_s
          (fun acc (e : Corruption.entry) ->
            let+ outcome = repair_one ~source ~dry_run e in
            let acc = { acc with checked = acc.checked + 1 } in
            on_chunk ~done_:acc.checked ~total ~chunk_key:e.Corruption.chunk_key
              ~store:e.Corruption.store outcome;
            match outcome with
              | Repaired _ -> { acc with repaired = acc.repaired + 1 }
              | Cleared -> { acc with cleared = acc.cleared + 1 }
              | Unrepairable ->
                  {
                    acc with
                    unrepairable = acc.unrepairable + 1;
                    lost = acc.lost @ [e.Corruption.chunk_key];
                  })
          no_repairs report.Corruption.entries
      in
      if not dry_run then Cor.invalidate ();
      Io.return stats
  end
end
