open Lwt.Syntax

(* A composite Backend.S over several sub-backends, each with a role:
   - main: the writable source of truth.
   - backfill: a writable but incomplete copy, lazily filled with served chunks.
   - readOnly: an authoritative store read only as a fallback, never written.

   Routing:
   - chunk keys: first-available read over the whole read order (main first),
     falling through on a miss *or* an error; on a hit, lazily backfill the served
     bytes into every backfill target that lacks them (background, bounded, deduped).
     Chunks are content-addressed/immutable, so this is always safe.
   - everything else (manifests, journal, cursor, versions) and all listings: read
     first-available over the non-backfill backends (main, then readOnly), falling
     through only on error — a definitive "not found" is trusted. Backfill copies are
     incomplete, so they are never consulted for these.
   - writes: fan out to the writable backends (everything except readOnly). *)

type sub = { name : string; backend : (module Backend.S) }

(* [read_order]: all sub-backends in read preference (main first) — chunk reads.
   [manifest_read]: the non-backfill backends (main, then readOnly) — manifests and
     listings, with error-triggered fallback.
   [writes]: the writable backends (all except readOnly) — write fan-out.
   [backfills]: incomplete backends to lazily fill with served chunks. *)
let make ~chunk_prefix ~(read_order : sub list) ~(manifest_read : sub list)
    ~(writes : (module Backend.S) list) ~(backfills : sub list) :
    (module Backend.S) =
  let is_chunk key = String.starts_with ~prefix:chunk_prefix key in
  let all_read = List.map (fun s -> s.backend) read_order in
  (* Bound concurrent backfill IO so it can't stampede slow storage. *)
  let pool = Lwt_pool.create 8 (fun () -> Lwt.return_unit) in
  (* Keys already ensured present in a given target — avoids repeat HEAD/PUT. *)
  let ensured : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
  let index_of name =
    let rec go i = function
      | [] -> max_int
      | (s : sub) :: _ when s.name = name -> i
      | _ :: r -> go (i + 1) r
    in
    go 0 read_order
  in
  (* Copy [data] into each backfill target that lacks [key]. A target that sits
     before the serving backend in the read order already missed (put directly);
     otherwise HEAD first. *)
  let schedule_backfill ~served key data =
    List.iter
      (fun (t : sub) ->
        let tag = t.name ^ "\000" ^ key in
        if t.name = served || Hashtbl.mem ensured tag then ()
        else
          Lwt.async (fun () ->
              Lwt_pool.use pool (fun () ->
                  Lwt.catch
                    (fun () ->
                      let module T = (val t.backend : Backend.S) in
                      let* absent =
                        if index_of t.name < index_of served then
                          Lwt.return_true
                        else
                          let+ h = T.head_opt ~key () in
                          h = None
                      in
                      let* () =
                        if absent then T.put ~key ~data () else Lwt.return_unit
                      in
                      Hashtbl.replace ensured tag ();
                      Lwt.return_unit)
                    (fun exn ->
                      Log.warn "tiered backfill %s->%s: %s" served t.name
                        (Printexc.to_string exn);
                      Lwt.return_unit))))
      backfills
  in
  (* First-available get over the read order; a backend that misses (None) or is
     unreachable (raises) is skipped. Returns the data and which backend served it. *)
  let read_chunk_opt key =
    let rec go = function
      | [] -> Lwt.return_none
      | (s : sub) :: rest -> (
          let* outcome =
            Lwt.catch
              (fun () ->
                let module B = (val s.backend : Backend.S) in
                let+ d = B.get_opt ~key () in
                `Got d)
              (fun exn ->
                Log.warn "tiered chunk read: %s unavailable (%s); trying next"
                  s.name (Printexc.to_string exn);
                Lwt.return `Err)
          in
          match outcome with
            | `Got (Some data) -> Lwt.return (Some (data, s.name))
            | `Got None | `Err -> go rest)
    in
    go read_order
  in
  (* First-available call over the non-backfill backends: fall through on error,
     but trust a successful result (including a definitive [None]). *)
  let manifest_first label f =
    let rec go = function
      | [] ->
          Lwt.fail
            (Backend.Backend_error ("tiered " ^ label ^ ": no readable backend"))
      | [(s : sub)] -> f s.backend
      | (s : sub) :: rest ->
          Lwt.catch
            (fun () -> f s.backend)
            (fun exn ->
              Log.warn "tiered %s: %s unavailable (%s); trying next" label
                s.name (Printexc.to_string exn);
              go rest)
    in
    go manifest_read
  in
  (module struct
    let put ~key ~data () =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.put ~key ~data ()) writes

    let get_opt ~key () =
      if is_chunk key then
        let+ r = read_chunk_opt key in
        match r with
          | Some (data, served) ->
              schedule_backfill ~served key data;
              Some data
          | None -> None
      else
        manifest_first "get_opt" (fun (module B : Backend.S) ->
            B.get_opt ~key ())

    let get ~key () =
      if is_chunk key then
        let* r = read_chunk_opt key in
        match r with
          | Some (data, served) ->
              schedule_backfill ~served key data;
              Lwt.return data
          | None ->
              Lwt.fail (Backend.Backend_error ("tiered get: not found: " ^ key))
      else manifest_first "get" (fun (module B : Backend.S) -> B.get ~key ())

    let head_opt ~key () =
      if is_chunk key then (
        let rec go = function
          | [] -> Lwt.return_none
          | (s : sub) :: rest -> (
              let* outcome =
                Lwt.catch
                  (fun () ->
                    let module B = (val s.backend : Backend.S) in
                    let+ h = B.head_opt ~key () in
                    `Got h)
                  (fun exn ->
                    Log.warn
                      "tiered chunk head: %s unavailable (%s); trying next"
                      s.name (Printexc.to_string exn);
                    Lwt.return `Err)
              in
              match outcome with
                | `Got (Some _ as h) -> Lwt.return h
                | `Got None | `Err -> go rest)
        in
        go read_order)
      else
        manifest_first "head_opt" (fun (module B : Backend.S) ->
            B.head_opt ~key ())

    let delete ~key () =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.delete ~key ()) writes

    let delete_multi keys =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.delete_multi keys) writes

    let copy ~src_key ~dst_key () =
      Lwt_list.iter_s
        (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
        writes

    let list_all ?max_keys ~prefix () =
      manifest_first "list_all" (fun (module B : Backend.S) ->
          B.list_all ?max_keys ~prefix ())

    let list_directory ~prefix () =
      manifest_first "list_directory" (fun (module B : Backend.S) ->
          B.list_directory ~prefix ())

    let share_url ~prefix () =
      let rec go = function
        | [] -> Lwt.return_none
        | (module B : Backend.S) :: rest -> (
            let* u = B.share_url ~prefix () in
            match u with Some _ -> Lwt.return u | None -> go rest)
      in
      go all_read
  end)
