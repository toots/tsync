open Lwt.Syntax

type phase = Opening | Marking | Abandoning | Closing
type run = { phase : phase; started : float; cursor : string }

let string_of_phase = function
  | Opening -> "opening"
  | Marking -> "marking"
  | Abandoning -> "abandoning"
  | Closing -> "closing"

let phase_of_string = function
  | "opening" -> Some Opening
  | "marking" -> Some Marking
  | "abandoning" -> Some Abandoning
  | "closing" -> Some Closing
  (* A marker an older binary left behind, when deleting on the copies was a
     phase of its own after this one. Read as [Closing] rather than as garbage:
     an unreadable marker reads as an idle store, which would strand
     [chunks.from/] on disk for good. Nothing is left to do by then — the old
     space is already discarded — so the close pass finds it empty and
     finishes. *)
  | "reconciling" -> Some Closing
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
        Option.bind
          (phase_of_string (str "phase"))
          (fun phase ->
            Some { phase; started = num "started"; cursor = str "cursor" })
    | _ -> None
    | exception _ -> None

(* [chunk_prefix] is "<domain root>/chunks/", and both of these are its siblings
   rather than its children: what opens a run is renaming the chunk root itself
   out of the way, so nothing that has to survive that can live inside it.

   Outside the functor because {!Deferred} is built before there is a {!Conf.S}
   to apply one to, and it needs the from-space prefix too. *)
let marker_key ~chunk_prefix =
  Stored_key.in_space
    ~prefix:(Filename.chop_suffix chunk_prefix "chunks/")
    "gc-run"

module Make (C : Conf.S) = struct
  module B = (val C.store : Backend.S)
  module L = Chunk_layout.Make (C)

  let marker_key = marker_key ~chunk_prefix:C.chunk_prefix

  (* The main is where both spaces are: a run renames a directory and links
     within it, so only the store holding the chunks can be mid-run. *)
  let main_backend =
    lazy
      (List.find_opt
         (fun (m : Backend.member) -> m.Backend.role = `Main)
         C.members)

  let main () =
    match Lazy.force main_backend with
      | Some m -> Some m.Backend.backend
      | None -> None

  (* Promotion is a rename between two directories of one filesystem, so it
     needs the path rather than the store: the same reason {!Gc} opens and closes
     a run through [Lwt_unix] on it instead of through a backend.

     Also what says a run is possible at all, which keeps a store that will never
     be collected — s3, gcs, a proxy — on the single-lookup path below: no second
     key, no marker. *)
  let local_root () =
    match Lazy.force main_backend with
      | Some m -> m.Backend.local_path
      | None -> None

  (* The marker describes one store's own state, so it goes to the main directly:
     through the composite every write would fan out to each replica and backfill
     target, leaving them carrying a marker about a collection that is not theirs
     and that they can do nothing with. *)
  let marker_store () =
    match main () with Some b -> b | None -> (module B : Backend.S)

  let read_run () =
    let (module Mk : Backend.S) = marker_store () in
    let* data = Mk.get_opt ~key:marker_key () in
    match data with
      | None -> Lwt.return_none
      | Some data -> (
          match of_string (Bigstring.to_string data) with
            | Some run -> Lwt.return_some run
            | None ->
                (* Written by [put], so it is either absent or whole: garbage
                   here means someone else put it there. *)
                Log.warn "chunk space: unreadable run marker %s; treating %s"
                  (Stored_key.to_string marker_key)
                  "the store as idle";
                Lwt.return_none)

  let write_run run =
    let (module Mk : Backend.S) = marker_store () in
    Mk.put ~key:marker_key ~data:(Bigstring.of_string (to_string run)) ()

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
     The surviving space first, which is where marking moves each live chunk and
     where every write has always landed: only a live chunk marking has not
     reached yet costs the second lookup, and once marking is done nothing does.

     Order is a cost, not a correctness matter — both names are tried either way.
     Believing the cache is what buys the single lookup, and nothing believes it
     in the direction where being wrong would matter — see {!missed}. *)
  let candidates chunk_key =
    let+ running = probably_running () in
    if running then [L.key chunk_key; L.from_key chunk_key]
    else [L.key chunk_key]

  (* One more place to look once every candidate has missed. A store the cache
     called idle has only been asked about one space and the cache may be behind
     a run that opened since, so the marker is read for real before a miss
     becomes an answer — which is why the TTL above is a performance knob with no
     correct value.

     Nothing more to try when the cache already said a run was open: both spaces
     were asked. *)
  let missed chunk_key =
    let* running = probably_running () in
    if running then Lwt.return_none
    else
      let+ opened = refresh_order () in
      if opened then Some (L.from_key chunk_key) else None

  (* A move, not a copy: what stays behind in the space on its way out is then
     the garbage itself, which is what lets a collection delete by name instead
     of working the difference out again per shard. It also drops the one
     filesystem requirement a link imposed — [Local_backend.copy] answers a
     filesystem with no links to give by rewriting the body, which on such a
     store turns a collection into a rewrite of the whole live set.

     The rename itself answers where the chunk is, no [head_opt] first: doubling
     the cost of the one operation a collection performs millions of times to
     learn what the call is about to say anyway.

     [ENOENT] means either name — a chunk already across, or a shard directory
     not made yet — so the destination is made sure of and the rename tried once
     more; a second [ENOENT] is the source's and the chunk is already where it
     belongs. Promotion stays idempotent either way, which is what a resumed mark
     rests on. Making the parent first instead would be a [stat] per chunk to
     learn what is almost always already true. *)
  let promote chunk_key =
    match local_root () with
      | None -> Lwt.return_false
      | Some root ->
          let src =
            Filename.concat root (Stored_key.to_string (L.from_key chunk_key))
          and dst =
            Filename.concat root (Stored_key.to_string (L.key chunk_key))
          in
          let rec attempt ~parent_made =
            Lwt.catch
              (fun () ->
                let+ () = Io_lwt.Retry.rename src dst in
                true)
              (function
                | Unix.Unix_error (Unix.ENOENT, _, _) when not parent_made ->
                    let* () = Fs_util.ensure_parent dst in
                    attempt ~parent_made:true
                | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_false
                | exn -> Lwt.fail exn)
          in
          attempt ~parent_made:false

  (* Called immediately before a manifest is published, and this — not the
     presence check below — is what makes a run safe.

     Tying survival to the publish rather than to how each chunk was found covers
     the cases a check cannot: a chunk skipped by an uploader's own session memo
     (see {!Dedup}), a chunk written before the run opened and moved
     by the rename since, an upload still in flight when the run opened. *)
  let promote_all ~count chunk_key =
    let* run = read_run () in
    match run with
      | None -> Lwt.return_unit
      | Some _ ->
          let rec go i =
            if i >= count then Lwt.return_unit
            else
              let* (_ : bool) = promote (chunk_key i) in
              go (i + 1)
          in
          go 0

  (* The two lookups below are spelled out rather than shared through a
     combinator, because they differ in what "not there" is: an option for one, a
     raised failure for the other.

     Both ask the main's spaces first and the composite only once those have
     missed: routing a miss through the composite would walk past the main to a
     replica, which during a run is nearly every read — an object-store request
     per chunk, for as long as the run lasts. *)

  (* Deliberately does not promote what it finds in the space on its way out:
     {!promote_all} at publish time is what a chunk's survival hangs on, and one
     mechanism for that is easier to be sure of than two. *)
  let head chunk_key =
    match (local_root (), main ()) with
      | None, _ | _, None -> B.head_opt ~key:(L.key chunk_key) ()
      | Some _, Some (module M : Backend.S) ->
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
                           the composite's job. *)
                        | None -> B.head_opt ~key:(L.key chunk_key) ())
                  | None -> B.head_opt ~key:(L.key chunk_key) ())
            | k :: rest ->
                let* found = M.head_opt ~key:k () in
                if found <> None then Lwt.return found else first rest
          in
          first keys

  (* Reading does not promote: it says nothing about whether anything still
     references the chunk, and whatever does is a root the mark reaches anyway.

     The last attempt is a [get], not a [get_opt], so a chunk that is simply gone
     is reported in the store's own words. *)
  let get chunk_key =
    match (local_root (), main ()) with
      | None, _ | _, None -> B.get ~key:(L.key chunk_key) ()
      | Some _, Some (module M : Backend.S) ->
          let* keys = candidates chunk_key in
          let rec first = function
            | [] -> B.get ~key:(L.key chunk_key) ()
            | k :: rest -> (
                let* found = M.get_opt ~key:k () in
                match found with
                  | Some data -> Lwt.return data
                  | None -> first rest)
          in
          first keys
end
