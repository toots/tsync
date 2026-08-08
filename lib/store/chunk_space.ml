open Lwt.Syntax

type phase = Opening | Marking | Closing | Reconciling

type run = { phase : phase; started : float; cursor : string }

let string_of_phase = function
  | Opening -> "opening"
  | Marking -> "marking"
  | Closing -> "closing"
  | Reconciling -> "reconciling"

let phase_of_string = function
  | "opening" -> Some Opening
  | "marking" -> Some Marking
  | "closing" -> Some Closing
  | "reconciling" -> Some Reconciling
  | _ -> None

let to_string { phase; started; cursor } =
  Yojson.Basic.to_string
    (`Assoc
       [
         ("phase", `String (string_of_phase phase));
         ("started", `Float started);
         ("cursor", `String cursor);
       ])

let of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields ->
        let str k =
          match List.assoc_opt k fields with Some (`String s) -> s | _ -> ""
        in
        let num k =
          match List.assoc_opt k fields with
            | Some (`Float f) -> f
            | Some (`Int i) -> float_of_int i
            | _ -> 0.
        in
        Option.bind (phase_of_string (str "phase")) (fun phase ->
            Some { phase; started = num "started"; cursor = str "cursor" })
    | _ -> None
    | exception _ -> None

(* [chunk_prefix] is "<domain root>/chunks/", and both of these are its siblings
   rather than its children: what opens a run is renaming the chunk root itself
   out of the way, so nothing that has to survive that can live inside it.

   Derived from the chunk prefix rather than carried on {!Conf.S}, where every
   config module — including one per test — would have to name two keys only this
   module and {!Gc} ever touch. Safe by construction:
   {!Conf_parsing.chunk_prefix} is the one thing that builds a chunk prefix and
   always ends this way.

   Outside the functor because {!Deferred} is built before there is a {!Conf.S} to
   apply one to, and it needs the from-space prefix too. One definition, so the
   two cannot drift into disagreeing about where the space is. *)
let domain_root ~chunk_prefix = Filename.chop_suffix chunk_prefix "chunks/"
let from_prefix ~chunk_prefix = domain_root ~chunk_prefix ^ "chunks.from/"
let marker_key ~chunk_prefix = domain_root ~chunk_prefix ^ "gc-run"

module Make (C : Conf.S) = struct
  module B = (val C.store : Backend.S)

  let from_prefix = from_prefix ~chunk_prefix:C.chunk_prefix
  let marker_key = marker_key ~chunk_prefix:C.chunk_prefix

  let key chunk_key = C.chunk_prefix ^ Chunk_layout.relative_path chunk_key

  let from_key chunk_key = from_prefix ^ Chunk_layout.relative_path chunk_key

  (* The main is where both spaces are: a run renames a directory and links
     within it, so only the store holding the chunks can be mid-run. *)
  let main_backend =
    lazy
      (List.find_opt
         (fun (m : Backend.member) -> m.Backend.role = "main")
         C.members)

  let main () =
    match Lazy.force main_backend with
      | Some m -> Some m.Backend.backend
      | None -> None

  (* Whether the main can be mid-run at all. Static for the life of the process,
     and the promise is memoized so concurrent lookups share one probe.

     This is what keeps a store that will never be collected — s3, gcs, a proxy —
     on exactly the lookup path it had before any of this existed: one probe of
     one space, no second key, no marker. *)
  let capable = ref None

  let is_capable () =
    match !capable with
      | Some p -> p
      | None ->
          let p =
            match main () with
              | None -> Lwt.return_false
              | Some (module M : Backend.S) ->
                  let+ caps = M.capabilities ~prefix:C.domain_prefix () in
                  caps.Backend.gc
          in
          capable := Some p;
          p

  (* The marker describes one store's own state, so it is read from and written to
     the main directly and never through the composite. Through it, every write
     would be fanned out to each replica and backfill target — once per batch of a
     collection — leaving them carrying a marker about a collection that is not
     theirs and that they can do nothing with. *)
  let marker_store () =
    match main () with Some b -> b | None -> (module B : Backend.S)

  let read_run () =
    let (module Mk : Backend.S) = marker_store () in
    let* data = Mk.get_opt ~key:marker_key () in
    match data with
      | None -> Lwt.return_none
      | Some data -> (
          match of_string data with
            | Some run -> Lwt.return_some run
            | None ->
                (* Written by [put], so it is either absent or whole. Garbage
                   here means someone else put it there; say so rather than
                   silently reading the store as idle. *)
                Log.warn "chunk space: unreadable run marker %s; treating %s"
                  marker_key "the store as idle";
                Lwt.return_none)

  let write_run run =
    let (module Mk : Backend.S) = marker_store () in
    Mk.put ~key:marker_key ~data:(to_string run) ()

  let clear_run () =
    let (module Mk : Backend.S) = marker_store () in
    Mk.delete ~key:marker_key ()

  (* Whether a run is open, cached: reading the marker per chunk lookup would cost
     more than the lookup it saves. *)
  let order_ttl = 5.
  let order_checked = ref neg_infinity
  let running = ref false

  let refresh_order () =
    let+ run = read_run () in
    order_checked := Unix.gettimeofday ();
    running := run <> None;
    !running

  let probably_running () =
    if Unix.gettimeofday () -. !order_checked < order_ttl then
      Lwt.return !running
    else refresh_order ()

  (* The keys on the main that could hold [chunk_key], in the order worth trying.
     While a run is open the space on its way out holds everything that existed
     when the run started, which is nearly everything, so that is where to look
     first and one lookup does it; only a chunk written during the run needs the
     second. An idle store looks in one place and is done.

     Believing the cache is what buys the single lookup. Nothing believes it in
     the direction where being wrong would matter: see {!missed}. *)
  let candidates chunk_key =
    let+ running = probably_running () in
    if running then [from_key chunk_key; key chunk_key] else [key chunk_key]

  (* One more place to look once every candidate has missed.

     A store the cache called idle has only been asked about one space, and the
     cache may be behind a run that opened since — so before a miss is reported as
     an answer, the marker is read for real. This is what keeps a stale cache from
     turning into a wrong answer, and it is why the TTL above is a performance knob
     with no correct value rather than something to get right.

     Nothing more to try when the cache already said a run was open: both spaces
     were asked. *)
  let missed chunk_key =
    let* running = probably_running () in
    if running then Lwt.return_none
    else
      let+ opened = refresh_order () in
      if opened then Some (from_key chunk_key) else None

  (* Give [chunk_key] a name in the space that survives the run, and nothing at all
     when it is not in the space on its way out — so a caller can promote whatever
     it names without first asking where any of it is.

     Asked before copied, rather than copying and forgiving the failure: a copy
     whose source is missing is a real error for every other caller, and a driver
     is free to report it however it likes. Most calls land here anyway —
     {!promote_all} runs over every chunk a manifest names and the freshly written
     ones are in the surviving space already — so this is the common path, not the
     exception.

     Idempotent: the local driver's [copy] links, and counts an existing
     destination as done, so a resumed run redoes a chunk for the price of one
     failed link. *)
  let promote chunk_key =
    match main () with
      | None -> Lwt.return_unit
      | Some (module M : Backend.S) -> (
          let src = from_key chunk_key in
          let* there = M.head_opt ~key:src () in
          match there with
            | None -> Lwt.return_unit
            | Some _ -> M.copy ~src_key:src ~dst_key:(key chunk_key) ())

  (* Every chunk a manifest names, given a name in the surviving space — called
     immediately before the manifest is published.

     This, and not the presence check below, is what makes a run safe. Tying it
     to the publish rather than to how each chunk was found covers the cases a
     check cannot: a chunk skipped by an uploader's own session memo (see
     [Remote.known_chunks]), a chunk this process wrote before the run opened and
     that the rename has since moved, and an upload still in flight when the run
     opened. The invariant is "a manifest is visible only once every chunk it
     names has a name in the surviving space", and it holds however the chunk got
     there.

     One marker read per published manifest when the store is idle, which is the
     cheapest thing a publish does. *)
  let promote_all chunk_keys =
    let* run = read_run () in
    match run with
      | None -> Lwt.return_unit
      | Some _ -> Lwt_list.iter_s promote chunk_keys

  (* Ask the main for each candidate in turn, then the domain. Spelled out twice
     below rather than shared through a combinator, because the two differ in
     what "not there" is: an option for one, a raised failure for the other.

     The main's spaces come first, and the composite only once both have missed.
     Routing a miss through the composite instead would walk past the main to a
     replica, which during a run is nearly every read — an object-store request
     per chunk, for as long as the run lasts. *)

  (* Whether the store holds [chunk_key]. Deliberately does not promote what it
     finds in the space on its way out: {!promote_all} at publish time is what a
     chunk's survival hangs on, and one mechanism for that is easier to be sure
     of than two. Falling through still matters, so that an uploader holding the
     chunk does not re-send one that is merely waiting to be promoted. *)
  let head chunk_key =
    let* capable = is_capable () in
    match (capable, main ()) with
      | false, _ | _, None -> B.head_opt ~key:(key chunk_key) ()
      | true, Some (module M : Backend.S) ->
          let* keys = candidates chunk_key in
          let rec first = function
            | [] -> (
                let* extra = missed chunk_key in
                match extra with
                  | Some k -> (
                      let* found = M.head_opt ~key:k () in
                      match found with
                        | Some _ -> Lwt.return found
                        (* A replica may hold a chunk the main has lost, which is
                           the composite's job and was true before any of this. *)
                        | None -> B.head_opt ~key:(key chunk_key) ())
                  | None -> B.head_opt ~key:(key chunk_key) ())
            | k :: rest ->
                let* found = M.head_opt ~key:k () in
                if found <> None then Lwt.return found else first rest
          in
          first keys

  (* The chunk body, from whichever space holds it.

     Reading does not promote: it says nothing about whether anything still
     references the chunk, and whatever does is a root the mark reaches anyway.

     The last attempt goes through the composite and is a [get], not a [get_opt],
     so a chunk that is simply gone is reported in the store's own words rather
     than in a sentence duplicated here. *)
  let get chunk_key =
    let* capable = is_capable () in
    match (capable, main ()) with
      | false, _ | _, None -> B.get ~key:(key chunk_key) ()
      | true, Some (module M : Backend.S) ->
          let* keys = candidates chunk_key in
          let rec first = function
            | [] -> B.get ~key:(key chunk_key) ()
            | k :: rest -> (
                let* found = M.get_opt ~key:k () in
                match found with
                  | Some data -> Lwt.return data
                  | None -> first rest)
          in
          first keys
end
