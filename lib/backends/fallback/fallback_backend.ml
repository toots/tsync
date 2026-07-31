open Lwt.Syntax

(* A composite Backend.S that composes the readable backends into one, in role
   order, and decides how far a read is allowed to look.

   Two groups:

   - [writable] — the [main] backends and then the [replica]s. Every write fans
     out over all of them, so they hold the same content and any live one can
     speak for the source of truth. A read walks them and takes the first answer
     from one that is reachable; a definitive "not found" from that one is the
     answer, because the next one holds the same thing.
   - [fallbacks] — the [readOnly] stores. Different content (an old bucket still
     worth serving, never worth writing), so they are consulted both when the
     source of truth says no and when none of it is reachable. Never written.

   When nothing answers and nothing is left to try, the last error is re-raised.
   Swallowing it into [None] would turn an unreachable backend into a confident
   ENOENT, which is the one outcome a caller must never be handed. *)

type sub = { name : string; backend : (module Backend.S) }

(* [writable]: mains then replicas — the head serves reads, a write fans out over
     all of them.
   [fallbacks]: read-only stores, consulted in order, never written. *)
let make ~(writable : sub list) ~(fallbacks : sub list) : (module Backend.S) =
  let inners = List.map (fun (s : sub) -> s.backend) writable in
  (* A read-only domain has nothing writable at all. Fanning out over the empty
     list would report success, so say so instead: a write that lands nowhere
     must not look like a write that landed. *)
  let write f =
    if inners = [] then Lwt.fail Backend.Not_writable
    else Lwt_list.iter_s f inners
  in
  (* Walk [chain] for an answer. [stop_on_miss] returns the first reachable
     backend's [None] as the answer; otherwise a miss moves on. Returns
     [`Answer]/[`Miss], or [`Unreachable exn] when every backend raised. *)
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
  (* The source of truth first, then the archives. A miss is only reported when
     every backend that could have held the key was actually asked: if any of
     them was unreachable, its error is what the caller gets, because "I could
     not look" must never reach a caller as "it is not there". *)
  let read label f =
    let* first = walk ~stop_on_miss:true label writable f in
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
       on, and listings are never merged: one backend's view wins. *)
    let list_prefix ?max_keys ~prefix () =
      let* r =
        read "list_prefix" (fun (module B : Backend.S) ->
            let+ l = B.list_prefix ?max_keys ~prefix () in
            Some l)
      in
      Lwt.return (Option.value r ~default:[])

    (* Shares and chunk sizes describe where new data goes, so only the writable
       backends have a say. *)
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
  end)
