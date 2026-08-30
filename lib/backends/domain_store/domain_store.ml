(* What the composite needs of the layer below: the settling every deferred
    target registers with, the batched reads a fan-out goes through, and the
    hook a process about to exit waits on. *)
module type DRAIN = sig
  type 'a io

  val on_drain : (unit -> unit io) -> unit
end

module Over
    (Io : Io.S)
    (Queues : Deferred.QUEUES with type 'a io := 'a Io.t)
    (Lock : Deferred.LOCKS with type 'a io := 'a Io.t)
    (Drain : DRAIN with type 'a io := 'a Io.t)
    (Bk : sig
      type slots

      module Batched (_ : Backend.S with type 'a io := 'a Io.t) : sig
        val get_many :
          ?slots:slots ->
          entries:Backend.file_entry list ->
          unit ->
          (Stored_key.t * Bigstring.t option) list Io.t
      end
    end) =
struct
  module Dt = Deferred.Over (Io) (Queues) (Lock)

  module type Store = Backend.S with type 'a io := 'a Io.t

  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  let rec iter_s f = function
    | [] -> Io.return ()
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  let rec map_s f = function
    | [] -> Io.return []
    | x :: rest ->
        let* y = f x in
        let+ rest = map_s f rest in
        y :: rest

  type sub = { name : string; backend : (module Store) }

  let drain () = Queues.settle_all ()

  (* {!drain} already covers every queue in the process, so the hook is worth
     registering once however many domains {!make} is called for. *)
  let hooked = ref false

  let hook_drain () =
    if not !hooked then begin
      hooked := true;
      Drain.on_drain drain
    end

  let rec make ~(mains : sub list)
      ~(targets : (source:(module Store) -> (module Dt.S)) list)
      ~(archives : sub list) : (module Store) =
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
        (fun (module D : Dt.S) ->
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
      if writers = [] then Io.fail Backend.Not_writable else iter_s f writers
    in
    (* Each target takes what it has a use for, in the order the mains took it. *)
    let fill op key =
      iter_s
        (fun (module D : Dt.S) ->
          if D.skip key then Io.return () else D.accept op)
        targets
    in
    (* [stop_on_miss] takes the first reachable store's [None] as the answer;
       otherwise a miss moves on. [`Unreachable exn] when every store raised. *)
    let walk ~stop_on_miss label chain f =
      let rec go last = function
        | [] -> (
            match last with
              | Some exn -> Io.return (`Unreachable exn)
              | None -> Io.return `Miss)
        | s :: rest -> (
            let* outcome =
              Io.catch
                (fun () ->
                  let module B = (val s.backend : Store) in
                  let+ v = f (module B : Store) in
                  `Got v)
                (fun exn ->
                  Log.warn "domain store %s: %s unavailable (%s); trying next"
                    label s.name (Printexc.to_string exn);
                  Io.return (`Err exn))
            in
            match outcome with
              | `Got (Some v) -> Io.return (`Answer v)
              | `Got None ->
                  if stop_on_miss then Io.return `Miss else go last rest
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
        | `Answer v -> Io.return (Some v)
        | _ -> (
            let unasked =
              match first with `Unreachable exn -> Some exn | _ -> None
            in
            let* second = walk ~stop_on_miss:false label archives f in
            match second with
              | `Answer v -> Io.return (Some v)
              | `Unreachable exn -> Io.fail (Option.value unasked ~default:exn)
              | `Miss -> (
                  match unasked with
                    | Some exn -> Io.fail exn
                    | None -> Io.return None))
    in
    (module struct
      let put ~key ~data () =
        let* () = write (fun (module B : Store) -> B.put ~key ~data ()) in
        fill (Deferred.Put { key; data }) key

      (* Arbitrated by the first main alone, then fanned out as an ordinary write:
         asking each main in turn would let two clients each win somewhere and
         disagree about who holds the name. *)
      let put_if_absent ~key ~data () =
        match mains with
          | [] -> Io.fail Backend.Not_writable
          | first :: rest ->
              let module A = (val first.backend : Store) in
              let* held = A.put_if_absent ~key ~data () in
              let* () =
                iter_s
                  (fun s ->
                    let module B = (val s.backend : Store) in
                    B.put ~key ~data:held ())
                  rest
              in
              let+ () = fill (Deferred.Put { key; data = held }) key in
              held

      let delete ~key () =
        let* () = write (fun (module B : Store) -> B.delete ~key ()) in
        fill (Deferred.Delete key) key

      let delete_multi keys =
        let* () = write (fun (module B : Store) -> B.delete_multi keys) in
        (* Filtered per target rather than through [fill], which decides for one
           key: a target may have a use for some of these and not others. *)
        iter_s
          (fun (module D : Dt.S) ->
            match List.filter (fun k -> not (D.skip k)) keys with
              | [] -> Io.return ()
              | keys -> D.accept (Deferred.Delete_multi keys))
          targets

      let copy ~src_key ~dst_key () =
        let* () =
          write (fun (module B : Store) -> B.copy ~src_key ~dst_key ())
        in
        fill (Deferred.Copy { src_key; dst_key }) dst_key

      let get_opt ~key () =
        read "get_opt" (fun (module B : Store) -> B.get_opt ~key ())

      let get_range ~key ~offset ~length () =
        read "get_range" (fun (module B : Store) ->
            B.get_range ~key ~offset ~length ())

      let head_opt ~key () =
        read "head_opt" (fun (module B : Store) -> B.head_opt ~key ())

      (* Where the cursor read goes and no wider: a wake from a store this does
         not read the cursor from says nothing about the one it does. *)
      let watch ~key ~last_seen () =
        let+ (_ : unit option) =
          read "watch" (fun (module B : Store) ->
              let+ () = B.watch ~key ~last_seen () in
              Some ())
        in
        ()

      (* Declared only where the first readable store has a batch of its own, and
         forwarding to it directly rather than through {!Bk.Batched}: the
         caller asking already holds a slot for this read, and taking a second
         from the same pool is how a fan-out deadlocks against itself. What it is
         handed is already packed to one request.

         Without one this stays [None], and the caller's own fan-out asks
         [get_opt] per key, which walks the members exactly as a single read does.

         Whatever the batch did not hold goes back through [read], the one place
         that tells a store which could not look from one that held nothing. Those
         asks are per key and sequential, which is what a miss costs: a batch's
         keys come from a listing of the very store being asked, so a miss is the
         rare case, and paying [read] for it keeps the archive fallback that makes
         a miss trustworthy. *)
      let get_many =
        let native =
          match readable with
            | [] -> None
            | s :: _ ->
                let module B = (val s.backend : Store) in
                Option.map (fun f -> (s.name, f)) B.get_many
        in
        match native with
          | None -> None
          | Some (name, native) ->
              Some
                (fun ~entries () ->
                  let* first =
                    Io.catch
                      (fun () -> native ~entries ())
                      (fun exn ->
                        Log.warn
                          "domain store get_many: %s unavailable (%s); asking \
                           key by key"
                          name (Printexc.to_string exn);
                        Io.return [])
                  in
                  let held = Hashtbl.create (List.length entries) in
                  List.iter
                    (fun (key, body) ->
                      match body with
                        | Some _ -> Hashtbl.replace held key body
                        | None -> ())
                    first;
                  map_s
                    (fun (e : Backend.file_entry) ->
                      match Hashtbl.find_opt held e.Backend.key with
                        | Some body -> Io.return (e.Backend.key, body)
                        | None ->
                            let+ body =
                              read "get_many" (fun (module B : Store) ->
                                  B.get_opt ~key:e.Backend.key ())
                            in
                            (e.Backend.key, body))
                    entries)

      let get ~key () =
        let* d = read "get" (fun (module B : Store) -> B.get_opt ~key ()) in
        match d with
          | Some d -> Io.return d
          (* Every store that could hold it was asked and none had it, an
             unreachable one having surfaced its own error out of [read]. Spelled
             in the drivers' vocabulary, so a caller classifying this reads it the
             same way as a 404 from one store. *)
          | None ->
              Io.fail
                (Retry.failed ~kind:Retry.Permanent ~op:"get"
                   ("not found: " ^ Stored_key.to_string key))

      (* An empty listing is a real answer, so only an unreachable store moves on.
         Listings are never merged: one store's view wins. *)
      let list_prefix ?max_keys ~prefix () =
        let* r =
          read "list_prefix" (fun (module B : Store) ->
              let+ l = B.list_prefix ?max_keys ~prefix () in
              Some l)
        in
        Io.return (Option.value r ~default:[])

      (* Fanned out to the mains and the readable targets, and summed: each store
         runs its own check, and one that cannot is not a reason the others should
         not. [`Unsupported] only when nothing at all could be asked.

         A backfill target is not reached, having no readable module to ask;
         [tsync data-integrity --verify] asks every configured member instead,
         which is what covers one that holds chunks nobody reads yet. *)
      let verify_all ~chunk_prefix () =
        let+ answers =
          map_s (fun (module B : Store) -> B.verify_all ~chunk_prefix ()) inners
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
        Io.return `Unsupported

      (* These describe where the domain's own data lives, so the archives have no
         say — a readable target does, being a full copy. *)
      let capabilities ~prefix () =
        let+ answers =
          map_s (fun (module B : Store) -> B.capabilities ~prefix ()) inners
        in
        Backend.merge_caps answers

      (* The main's alone: it is the store a read lands on, and a replica behind
         a link would make every read of this domain pay for a whole cache chunk
         where it wanted a few bytes. A domain with a disk in it has that disk as
         its main. *)
      let fast_read =
        match mains with
          | [] -> false
          | first :: _ ->
              let module M = (val first.backend : Store) in
              M.fast_read

      (* Several stores, so no one tree: a caller working on files reaches for the
         member it means ({!Collection} takes the main's) rather than the fan-out
         over all of them. *)
      let local_path = None
    end)
end
