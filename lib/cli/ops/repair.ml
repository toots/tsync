open Lwt.Syntax

type outcome = Repaired of { from_store : string } | Cleared | Unrepairable

type stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  lost : string list;
}

let empty =
  { checked = 0; repaired = 0; cleared = 0; unrepairable = 0; lost = [] }

let describe ~chunk_key ~store = function
  | Repaired { from_store } ->
      Printf.sprintf "FIXED %s on %s (from %s)" chunk_key store from_store
  | Cleared ->
      Printf.sprintf "STALE %s on %s (body was already correct)" chunk_key store
  | Unrepairable ->
      Printf.sprintf "LOST  %s on %s (no store holds these bytes)" chunk_key
        store

module Make (C : Conf_lwt.S) = struct
  module Cor = Corruption.Make (C)
  module L = Chunk_layout.Make (C)

  let good_body (module B : Backend_lwt.Store) chunk_key =
    Lwt.catch
      (fun () ->
        let+ body = B.get_opt ~key:(L.key chunk_key) () in
        match body with
          | Some body when Chunks.key_of_body body = chunk_key -> Some body
          | _ -> None)
      (fun _ -> Lwt.return_none)

  let member_named name =
    List.find_opt
      (fun (m : (module Backend_lwt.Store) Backend.member) ->
        m.Backend.name = name)
      C.members

  (* A backfill target is excluded by [readable]: it is not read from, and may
     not hold the chunk at all. *)
  let sources_for ~source ~bad_store =
    List.filter
      (fun (m : (module Backend_lwt.Store) Backend.member) ->
        m.Backend.name <> bad_store
        && m.Backend.readable
        && match source with None -> true | Some n -> m.Backend.name = n)
      C.members

  let rec first_good chunk_key = function
    | [] -> Lwt.return_none
    | (m : (module Backend_lwt.Store) Backend.member) :: rest -> (
        let* body = good_body m.Backend.backend chunk_key in
        match body with
          | Some body -> Lwt.return_some (m.Backend.name, body)
          | None -> first_good chunk_key rest)

  (* A stale marker is repaired by rewriting the body over itself rather than by
     removing the marker: the store has to be the one to conclude the object is
     fine — see the .mli. *)
  let repair_one ~source ~dry_run (e : Corruption.entry) =
    let chunk_key = e.Corruption.chunk_key in
    match member_named e.Corruption.store with
      | None -> Lwt.return Unrepairable
      | Some m -> (
          let (module Dst : Backend_lwt.Store) = m.Backend.backend in
          let write body =
            if dry_run then Lwt.return_unit
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
                  | None -> Lwt.return Unrepairable
                  | Some (from_store, body) ->
                      let+ () = write body in
                      Repaired { from_store }))

  let run ?source ?(dry_run = false) ?(on_start = fun ~total:_ -> ())
      ?(on_chunk = fun ~done_:_ ~total:_ ~chunk_key:_ ~store:_ _ -> ()) () =
    if C.read_only && not dry_run then
      failwith
        (Printf.sprintf "%s is read-only, so nothing here may be rewritten."
           C.domain_name);
    let* report = Cor.list () in
    let total = List.length report.Corruption.entries in
    on_start ~total;
    let* stats =
      Lwt_list.fold_left_s
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
        empty report.Corruption.entries
    in
    if not dry_run then Cor.invalidate ();
    Lwt.return stats
end
