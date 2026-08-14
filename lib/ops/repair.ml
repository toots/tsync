open Lwt.Syntax

type outcome = Repaired of { from_store : string } | Cleared | Unrepairable

type stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  bytes : int;
  lost : string list;
}

let empty =
  {
    checked = 0;
    repaired = 0;
    cleared = 0;
    unrepairable = 0;
    bytes = 0;
    lost = [];
  }

let describe ~chunk_key ~store = function
  | Repaired { from_store } ->
      Printf.sprintf "FIXED %s on %s (from %s)" chunk_key store from_store
  | Cleared ->
      Printf.sprintf "STALE %s on %s (body was already correct)" chunk_key store
  | Unrepairable ->
      Printf.sprintf "LOST  %s on %s (no store holds these bytes)" chunk_key
        store

module Make (C : Conf.S) = struct
  module Cor = Corruption.Make (C)
  module Space = Chunk_space.Make (C)

  (* Never trusted for coming from somewhere reputable: a copy can be wrong too,
     and writing one bad body over another spreads the damage under cover of
     repairing it. A chunk's key is the hash of its bytes, so every candidate
     carries its own proof and is made to show it. *)
  let good_body (module B : Backend.S) chunk_key =
    Lwt.catch
      (fun () ->
        let+ body = B.get_opt ~key:(Space.key chunk_key) () in
        match body with
          | Some body when Chunk_layout.key_of_body body = chunk_key ->
              Some body
          | _ -> None)
      (fun _ -> Lwt.return_none)

  let member_named name =
    List.find_opt (fun (m : Backend.member) -> m.Backend.name = name) C.members

  (* Configuration order, which {!Conf_parsing} has already put main first: the
     authoritative copy is the one to prefer, and a replica is worth asking only
     because the main is what may be broken. The store being repaired is never
     its own source, and a backfill target is not one either — it is not readable
     and may not hold the chunk at all.

     [source] narrows this to one named store, for an operator who knows which
     copy to trust. *)
  let sources_for ~source ~bad_store =
    List.filter
      (fun (m : Backend.member) ->
        m.Backend.name <> bad_store
        && m.Backend.readable
        && match source with None -> true | Some n -> m.Backend.name = n)
      C.members

  let rec first_good chunk_key = function
    | [] -> Lwt.return_none
    | (m : Backend.member) :: rest -> (
        let* body = good_body m.Backend.backend chunk_key in
        match body with
          | Some body -> Lwt.return_some (m.Backend.name, body)
          | None -> first_good chunk_key rest)

  (* Written to the marked store directly, not through {!Conf.store}: only one
     copy is wrong, and a fan-out write would re-send the chunk to healthy stores
     and queue deferred jobs for them.

     Nothing here deletes a marker. The store clears it by re-verifying the
     object as it takes it — which is the whole of how a repair is recorded, and
     is what stops a client that merely believes it fixed something from being
     able to say so. It is also why a stale marker is repaired by rewriting the
     body over itself rather than by removing the marker: the store must be the
     one to conclude the object is fine. *)
  let repair_one ~source ~dry_run (e : Corruption.entry) =
    let chunk_key = e.Corruption.chunk_key in
    match member_named e.Corruption.store with
      | None -> Lwt.return (Unrepairable, 0)
      | Some m -> (
          let (module Dst : Backend.S) = m.Backend.backend in
          let write body =
            if dry_run then Lwt.return_unit
            else Dst.put ~key:(Space.key chunk_key) ~data:body ()
          in
          (* Its own copy first. A cloud marker outlives the write that fixed the
             chunk whenever two object events arrive out of order, so a marker on
             a body that is already correct is an expected state and not a
             finding — and rewriting it is both the cheapest repair and the only
             thing that will clear it. *)
          let* mine = good_body m.Backend.backend chunk_key in
          match mine with
            | Some body ->
                let+ () = write body in
                (Cleared, String.length body)
            | None -> (
                let* found =
                  first_good chunk_key
                    (sources_for ~source ~bad_store:e.Corruption.store)
                in
                match found with
                  | None -> Lwt.return (Unrepairable, 0)
                  | Some (from_store, body) ->
                      let+ () = write body in
                      (Repaired { from_store }, String.length body)))

  let run ?source ?(dry_run = false)
      ?(on_chunk = fun ~chunk_key:_ ~store:_ _ -> ()) () =
    if C.read_only && not dry_run then
      failwith
        (Printf.sprintf "%s is read-only, so nothing here may be rewritten."
           C.domain_name);
    let* report = Cor.list () in
    let* stats =
      Lwt_list.fold_left_s
        (fun acc (e : Corruption.entry) ->
          let+ outcome, bytes = repair_one ~source ~dry_run e in
          on_chunk ~chunk_key:e.Corruption.chunk_key ~store:e.Corruption.store
            outcome;
          let acc = { acc with checked = acc.checked + 1 } in
          match outcome with
            | Repaired _ ->
                {
                  acc with
                  repaired = acc.repaired + 1;
                  bytes = acc.bytes + bytes;
                }
            | Cleared ->
                {
                  acc with
                  cleared = acc.cleared + 1;
                  bytes = acc.bytes + bytes;
                }
            | Unrepairable ->
                {
                  acc with
                  unrepairable = acc.unrepairable + 1;
                  lost = acc.lost @ [e.Corruption.chunk_key];
                })
        empty report.Corruption.entries
    in
    (* The memo holds a set this has just changed. *)
    if not dry_run then Cor.invalidate ();
    Lwt.return stats
end
