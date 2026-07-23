open Lwt.Syntax

(* A composite Backend.S over several sub-backends:
   - chunk keys: first-available read (main first), then lazily backfill the served
     bytes into every incomplete backend that lacks them — background, bounded,
     deduped. Chunks are content-addressed/immutable, so this is always safe.
   - everything else (manifests, journal, cursor, versions) and all listings: served
     from the single source-of-truth backend. Manifests are mutable and the engine
     caches/invalidates them itself, so they must never be read first-available.
   - writes: fan out to all sub-backends. *)

type sub = { name : string; backend : (module Backend.S) }

let starts_with s prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* [read_order]: all sub-backends in read preference (main first).
   [source]: the single non-backfill backend (source of truth).
   [backfills]: incomplete backends to lazily fill with served chunks. *)
let make ~chunk_prefix ~(source : (module Backend.S)) ~(read_order : sub list)
    ~(backfills : sub list) : (module Backend.S) =
  let is_chunk key = starts_with key chunk_prefix in
  let all = List.map (fun s -> s.backend) read_order in
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
  (* First-available get over the read order; returns the data and which backend
     served it. *)
  let read_chunk_opt key =
    let rec go = function
      | [] -> Lwt.return_none
      | (s : sub) :: rest -> (
          let module B = (val s.backend : Backend.S) in
          let* d = B.get_opt ~key () in
          match d with
            | Some data -> Lwt.return (Some (data, s.name))
            | None -> go rest)
    in
    go read_order
  in
  (module struct
    let put ~key ~data () =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.put ~key ~data ()) all

    let get_opt ~key () =
      if is_chunk key then
        let+ r = read_chunk_opt key in
        match r with
          | Some (data, served) ->
              schedule_backfill ~served key data;
              Some data
          | None -> None
      else
        let module S = (val source : Backend.S) in
        S.get_opt ~key ()

    let get ~key () =
      if is_chunk key then
        let* r = read_chunk_opt key in
        match r with
          | Some (data, served) ->
              schedule_backfill ~served key data;
              Lwt.return data
          | None ->
              Lwt.fail (Backend.Backend_error ("tiered get: not found: " ^ key))
      else
        let module S = (val source : Backend.S) in
        S.get ~key ()

    let head_opt ~key () =
      if is_chunk key then (
        let rec go = function
          | [] -> Lwt.return_none
          | (s : sub) :: rest -> (
              let module B = (val s.backend : Backend.S) in
              let* h = B.head_opt ~key () in
              match h with Some _ -> Lwt.return h | None -> go rest)
        in
        go read_order)
      else
        let module S = (val source : Backend.S) in
        S.head_opt ~key ()

    let delete ~key () =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.delete ~key ()) all

    let delete_multi keys =
      Lwt_list.iter_s (fun (module B : Backend.S) -> B.delete_multi keys) all

    let copy ~src_key ~dst_key () =
      Lwt_list.iter_s
        (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
        all

    let list_all ?max_keys ~prefix () =
      let module S = (val source : Backend.S) in
      S.list_all ?max_keys ~prefix ()

    let list_directory ~prefix () =
      let module S = (val source : Backend.S) in
      S.list_directory ~prefix ()

    let share_url ~prefix () =
      let rec go = function
        | [] -> Lwt.return_none
        | (module B : Backend.S) :: rest -> (
            let* u = B.share_url ~prefix () in
            match u with Some _ -> Lwt.return u | None -> go rest)
      in
      go all
  end)
