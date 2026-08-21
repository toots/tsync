open Lwt.Syntax

type sub = { name : string; backend : (module Backend.S) }

let drain () = Durable_queue.settle_all ()

(* {!drain} already covers every queue in the process, so the hook is worth
   registering once however many domains {!make} is called for. *)
let hooked = ref false

let hook_drain () =
  if not !hooked then begin
    hooked := true;
    Backend.on_drain drain
  end

let rec make ~(mains : sub list)
    ~(targets : (source:(module Backend.S) -> (module Deferred.S)) list)
    ~(archives : sub list) : (module Backend.S) =
  (* Each target catches up by re-reading from the source of truth and nothing
     else: a job is consumed once it succeeds, so a body read from a copy
     that is itself behind would land here and never be corrected. *)
  let targets =
    match targets with
      | [] -> []
      | _ ->
          hook_drain ();
          let source = make ~mains ~targets:[] ~archives:[] in
          List.map (fun spec -> spec ~source) targets
  in
  let readable_targets =
    List.filter_map
      (fun (module D : Deferred.S) ->
        Option.map (fun backend -> { name = D.name; backend }) D.readable)
      targets
  in
  (* Source of truth first, then the copies that are allowed to answer. *)
  let readable = mains @ readable_targets in
  let inners = List.map (fun s -> s.backend) readable in
  let writers = List.map (fun s -> s.backend) mains in
  (* Fanning out over an empty list would report success, and a write that lands
     nowhere must not look like one that landed. *)
  let write f =
    if writers = [] then Lwt.fail Backend.Not_writable
    else Lwt_list.iter_s f writers
  in
  (* Each target takes what it has a use for, in the order the mains took it. *)
  let fill op key =
    Lwt_list.iter_s
      (fun (module D : Deferred.S) ->
        if D.skip key then Lwt.return_unit else D.accept op)
      targets
  in
  (* [stop_on_miss] takes the first reachable store's [None] as the answer;
     otherwise a miss moves on. [`Unreachable exn] when every store raised. *)
  let walk ~stop_on_miss label chain f =
    let rec go last = function
      | [] -> (
          match last with
            | Some exn -> Lwt.return (`Unreachable exn)
            | None -> Lwt.return `Miss)
      | s :: rest -> (
          let* outcome =
            Lwt.catch
              (fun () ->
                let module B = (val s.backend : Backend.S) in
                let+ v = f (module B : Backend.S) in
                `Got v)
              (fun exn ->
                Log.warn "domain store %s: %s unavailable (%s); trying next"
                  label s.name (Printexc.to_string exn);
                Lwt.return (`Err exn))
          in
          match outcome with
            | `Got (Some v) -> Lwt.return (`Answer v)
            | `Got None ->
                if stop_on_miss then Lwt.return `Miss else go last rest
            | `Err exn -> go (Some exn) rest)
    in
    go None chain
  in
  (* A miss is reported only when every store that could hold the key was
     actually asked: an unreachable one surfaces its error, since "could not
     look" must not read as "not there". *)
  let read label f =
    let* first = walk ~stop_on_miss:true label readable f in
    match first with
      | `Answer v -> Lwt.return (Some v)
      | _ -> (
          let unasked =
            match first with `Unreachable exn -> Some exn | _ -> None
          in
          let* second = walk ~stop_on_miss:false label archives f in
          match second with
            | `Answer v -> Lwt.return (Some v)
            | `Unreachable exn -> Lwt.fail (Option.value unasked ~default:exn)
            | `Miss -> (
                match unasked with
                  | Some exn -> Lwt.fail exn
                  | None -> Lwt.return_none))
  in
  (module struct
    let put ~key ~data () =
      let* () = write (fun (module B : Backend.S) -> B.put ~key ~data ()) in
      fill (Deferred.Put { key; data }) key

    (* Arbitrated by the first main alone, then fanned out as an ordinary write:
       asking each main in turn would let two clients each win somewhere and
       disagree about who holds the name. *)
    let put_if_absent ~key ~data () =
      match mains with
        | [] -> Lwt.fail Backend.Not_writable
        | first :: rest ->
            let module A = (val first.backend : Backend.S) in
            let* held = A.put_if_absent ~key ~data () in
            let* () =
              Lwt_list.iter_s
                (fun s ->
                  let module B = (val s.backend : Backend.S) in
                  B.put ~key ~data:held ())
                rest
            in
            let+ () = fill (Deferred.Put { key; data = held }) key in
            held

    let delete ~key () =
      let* () = write (fun (module B : Backend.S) -> B.delete ~key ()) in
      fill (Deferred.Delete key) key

    let delete_multi keys =
      let* () = write (fun (module B : Backend.S) -> B.delete_multi keys) in
      (* Filtered per target rather than through [fill], which decides for one
         key: a target may have a use for some of these and not others. *)
      Lwt_list.iter_s
        (fun (module D : Deferred.S) ->
          match List.filter (fun k -> not (D.skip k)) keys with
            | [] -> Lwt.return_unit
            | keys -> D.accept (Deferred.Delete_multi keys))
        targets

    let copy ~src_key ~dst_key () =
      let* () =
        write (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
      in
      fill (Deferred.Copy { src_key; dst_key }) dst_key

    let get_opt ~key () =
      read "get_opt" (fun (module B : Backend.S) -> B.get_opt ~key ())

    let head_opt ~key () =
      read "head_opt" (fun (module B : Backend.S) -> B.head_opt ~key ())

    (* The first readable store answers in one request where it has one, and
       whatever it did not hold goes back through [read], which is the one place
       that tells a store which could not look from one that held nothing.

       Those second asks are per key and sequential, which is what a miss costs:
       the keys of a batch come from a listing of the very store being asked, so
       a miss is the rare case and paying [read] for it keeps the archive
       fallback that makes a miss trustworthy. *)
    let get_many =
      Some
        (fun ~entries () ->
          let* first =
            match readable with
              | [] -> Lwt.return []
              | s :: _ ->
                  let module B = (val s.backend : Backend.S) in
                  let module Bb = Backend.Batched (B) in
                  Lwt.catch
                    (fun () -> Bb.get_many ~entries ())
                    (fun exn ->
                      Log.warn
                        "domain store get_many: %s unavailable (%s); asking key \
                         by key"
                        s.name (Printexc.to_string exn);
                      Lwt.return [])
          in
          let held = Hashtbl.create (List.length entries) in
          List.iter
            (fun (key, body) ->
              match body with
                | Some _ -> Hashtbl.replace held key body
                | None -> ())
            first;
          Lwt_list.map_s
            (fun (e : Backend.file_entry) ->
              match Hashtbl.find_opt held e.Backend.key with
                | Some body -> Lwt.return (e.Backend.key, body)
                | None ->
                    let+ body =
                      read "get_many" (fun (module B : Backend.S) ->
                          B.get_opt ~key:e.Backend.key ())
                    in
                    (e.Backend.key, body))
            entries)

    let get ~key () =
      let* d = read "get" (fun (module B : Backend.S) -> B.get_opt ~key ()) in
      match d with
        | Some d -> Lwt.return d
        (* Every store that could hold it was asked and none had it, an
           unreachable one having surfaced its own error out of [read]. Spelled
           in the drivers' vocabulary, so a caller classifying this reads it the
           same way as a 404 from one store. *)
        | None ->
            Lwt.fail
              (Backend.failed ~kind:Backend.Permanent ~op:"get"
                 ("not found: " ^ key))

    (* An empty listing is a real answer, so only an unreachable store moves on.
       Listings are never merged: one store's view wins. *)
    let list_prefix ?max_keys ~prefix () =
      let* r =
        read "list_prefix" (fun (module B : Backend.S) ->
            let+ l = B.list_prefix ?max_keys ~prefix () in
            Some l)
      in
      Lwt.return (Option.value r ~default:[])

    (* Fanned out to the mains and the readable targets, and summed: each store
       runs its own check, and one that cannot is not a reason the others should
       not. [`Unsupported] only when nothing at all could be asked.

       A backfill target is not reached, having no readable module to ask;
       [tsync data-integrity --verify] asks every configured member instead,
       which is what covers one that holds chunks nobody reads yet. *)
    let verify_all ~chunk_prefix () =
      let+ answers =
        Lwt_list.map_s
          (fun (module B : Backend.S) -> B.verify_all ~chunk_prefix ())
          inners
      in
      let queued =
        List.fold_left
          (fun acc a ->
            match a with `Queued n -> acc + n | `Unsupported -> acc)
          0 answers
      in
      if List.exists (fun a -> a <> `Unsupported) answers then `Queued queued
      else `Unsupported

    (* Not the fan-out above it: {!Gc} asks each member itself, precisely so a
       store with a delete function and one without are handled differently, and
       the composite's own {!delete_multi} is what a caller wanting every member
       already has. *)
    let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
      Lwt.return `Unsupported

    (* These describe where the domain's own data lives, so the archives have no
       say — a readable target does, being a full copy. *)
    let capabilities ~prefix () =
      let+ answers =
        Lwt_list.map_s
          (fun (module B : Backend.S) -> B.capabilities ~prefix ())
          inners
      in
      Backend.merge_caps answers
  end)
