open Lwt.Syntax

(* A composite Backend.S composing the readable backends in role order, and
   deciding how far a read may look.

   - [sync] — the [main] backends. A write goes here and nowhere else, and
     returns once it has landed: this is the source of truth.
   - [deferred] — the [replica]s. Read behind the mains, but not written here:
     {!Lane_backend} carries them, so a slow or unreachable replica cannot hold
     up a write. They hold the same content as the mains eventually, which is why
     a read may fall through to one — a definitive "not found" from the first
     reachable backend still ends the read, so a failover read is behind by
     whatever its lane still owes.
   - [fallbacks] — the [readOnly] stores. Different content (an old bucket still
     worth serving, never worth writing), consulted both when the source of truth
     says no and when none of it is reachable. Never written.

   When nothing answers, the last error is re-raised: swallowing it into [None]
   would hand a caller a confident ENOENT from an unreachable backend. *)

type sub = { name : string; backend : (module Backend.S) }

(* [sync]: the mains — the head serves reads, and a write fans out over these
     alone.
   [deferred]: the replicas, read after the mains and written by their lane.
   [fallbacks]: read-only stores, consulted in order, never written. *)
let make ~(sync : sub list) ~(deferred : sub list) ~(fallbacks : sub list) :
    (module Backend.S) =
  let readable = sync @ deferred in
  (* Every store holding the domain's own content, for the questions that are
     about the stores rather than about one key. *)
  let inners = List.map (fun (s : sub) -> s.backend) readable in
  let writers = List.map (fun (s : sub) -> s.backend) sync in
  (* Fanning out over an empty list would report success, and a write that lands
     nowhere must not look like one that landed. *)
  let write f =
    if writers = [] then Lwt.fail Backend.Not_writable
    else Lwt_list.iter_s f writers
  in
  (* [stop_on_miss] takes the first reachable backend's [None] as the answer;
     otherwise a miss moves on. [`Unreachable exn] when every backend raised. *)
  let walk ~stop_on_miss label chain f =
    let rec go last = function
      | [] -> (
          match last with
            | Some exn -> Lwt.return (`Unreachable exn)
            | None -> Lwt.return `Miss)
      | (s : sub) :: rest -> (
          let* outcome =
            Lwt.catch
              (fun () ->
                let module B = (val s.backend : Backend.S) in
                let+ v = f (module B : Backend.S) in
                `Got v)
              (fun exn ->
                Log.warn "fallback %s: %s unavailable (%s); trying next" label
                  s.name (Printexc.to_string exn);
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
  (* Source of truth first, then the archives. A miss is reported only when every
     backend that could hold the key was actually asked: an unreachable one
     surfaces its error, since "could not look" must not read as "not there". *)
  let read label f =
    let* first = walk ~stop_on_miss:true label readable f in
    match first with
      | `Answer v -> Lwt.return (Some v)
      | _ -> (
          let unasked =
            match first with `Unreachable exn -> Some exn | _ -> None
          in
          let* second = walk ~stop_on_miss:false label fallbacks f in
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
      write (fun (module B : Backend.S) -> B.put ~key ~data ())

    let delete ~key () = write (fun (module B : Backend.S) -> B.delete ~key ())

    let delete_multi keys =
      write (fun (module B : Backend.S) -> B.delete_multi keys)

    let copy ~src_key ~dst_key () =
      write (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())

    let get_opt ~key () =
      read "get_opt" (fun (module B : Backend.S) -> B.get_opt ~key ())

    let head_opt ~key () =
      read "head_opt" (fun (module B : Backend.S) -> B.head_opt ~key ())

    let get ~key () =
      let* d = read "get" (fun (module B : Backend.S) -> B.get_opt ~key ()) in
      match d with
        | Some d -> Lwt.return d
        | None ->
            Lwt.fail (Backend.Backend_error ("fallback get: not found: " ^ key))

    (* An empty listing is a real answer, so only an unreachable backend moves
       on. Listings are never merged: one backend's view wins. *)
    let list_prefix ?max_keys ~prefix () =
      let* r =
        read "list_prefix" (fun (module B : Backend.S) ->
            let+ l = B.list_prefix ?max_keys ~prefix () in
            Some l)
      in
      Lwt.return (Option.value r ~default:[])

    (* These describe where the domain's own data lives, so the read-only
       archives have no say — a replica does, being a full copy. *)
    let share_url ~prefix () =
      let rec go = function
        | [] -> Lwt.return_none
        | (module B : Backend.S) :: rest -> (
            let* u = B.share_url ~prefix () in
            match u with Some _ -> Lwt.return u | None -> go rest)
      in
      go inners

    let default_chunk_size ~prefix () =
      let rec go = function
        | [] -> Lwt.return_none
        | (module B : Backend.S) :: rest -> (
            let* n = B.default_chunk_size ~prefix () in
            match n with Some _ -> Lwt.return n | None -> go rest)
      in
      go inners

    (* Unlike the chunk size this is a limit, not a preference, so it is the
       lowest any member holds rather than the first opinion found. *)
    let max_concurrency ~prefix () =
      let+ answers =
        Lwt_list.map_s
          (fun (module B : Backend.S) -> B.max_concurrency ~prefix ())
          inners
      in
      List.fold_left
        (fun acc n ->
          match (acc, n) with
            | Some a, Some b -> Some (min a b)
            | None, some | some, None -> some)
        None answers
  end)
