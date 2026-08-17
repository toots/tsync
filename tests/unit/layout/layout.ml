(* Placement rules for the two sharded stores. Both trade a flat directory for a
   shard, and both are only safe while the shard leaves the ordering and identity
   readers depend on undisturbed. *)

let check name cond = if not cond then failwith ("layout: " ^ name)

module Ek = Journal.Entry_key

(* Fixed epoch milliseconds rather than a run-time calendar:
   [Ek.relative_path] shards by UTC, so going through local time would file
   entries in a different month depending on where the test ran. *)
let entry ms =
  match Ek.of_string (Printf.sprintf "%013Ld-client" ms) with
    | Some ek -> ek
    | None -> failwith "layout: fixture entry key rejected"

let dec_31 = entry 1798718400000L (* 2026-12-31T12:00:00Z *)
let jan_01 = entry 1798804800000L (* 2027-01-01T12:00:00Z *)
let feb_01 = entry 1801483200000L (* 2027-02-01T12:00:00Z *)

let () =
  (* The key stays unchanged and recoverable, which every listing-side caller
     relies on. *)
  let k = "abbd5be7f7f1ea08-164c4bd493e0e119" in
  check "chunk shard" (Chunk_layout.relative_path k = "abb/" ^ k);
  check "chunk key survives"
    (Filename.basename (Chunk_layout.relative_path k) = k);
  check "short key" (Chunk_layout.relative_path "ab" = "_/ab");

  (* Entries apply in the order a listing sorts them, so the sharded path must
     sort like the bare entry keys — including across a month and a year
     boundary, where the shard changes. *)
  let dec = dec_31 and jan = jan_01 and feb = feb_01 in
  check "month shard" (Ek.relative_path jan = "2027-01/" ^ Ek.to_string jan);
  check "year boundary" (Ek.relative_path dec = "2026-12/" ^ Ek.to_string dec);
  check "entry key survives" (Ek.of_string (Ek.relative_path feb) = Some feb);
  check "entry keys ordered" (Ek.compare dec jan < 0 && Ek.compare jan feb < 0);
  (* An entry key is not itself a path under the journal prefix: a lookup built
     by concatenation lands somewhere no entry was ever written and reports the
     entry missing. Go through {!File_store.journal_entry_published}. *)
  check "entry key is not the object path"
    (Ek.relative_path feb <> Ek.to_string feb);
  check "sharded paths ordered in the same order"
    (Ek.relative_path dec < Ek.relative_path jan
    && Ek.relative_path jan < Ek.relative_path feb);

  (* [of_string] is the only parser, so what it accepts is what the rest of the
     code can assume it holds. *)
  check "round trips" (Ek.of_string (Ek.to_string feb) = Some feb);
  check "reads a backend listing key"
    (Ek.of_string ("tsync/dom/journal/" ^ Ek.relative_path feb) = Some feb);
  check "keeps the timestamp" (Ek.timestamp_ms feb = 1801483200000L);
  check "keeps the uuid" (Ek.client_uuid feb = "client");
  (* A month directory has a digits-then-dash shape too. Accepting a short
     timestamp would report a shard as an entry of its own. *)
  check "rejects a month directory" (Ek.of_string "2027-01" = None);
  check "rejects a short timestamp" (Ek.of_string "123-client" = None);
  check "rejects a non-numeric timestamp" (Ek.of_string "notatime-abc" = None);
  check "rejects a missing uuid" (Ek.of_string "1801483200000-" = None);
  check "rejects a bare prefix" (Ek.of_string "tsync/dom/journal/" = None);

  (* Markers and sweep requests carry the domain as their first segment, not
     inside a per-domain root. That is what lets one literal prefix cover every
     domain — a notification filter takes no wildcard, and Google's IAM
     conditions offer only [startsWith], so "tsync/<domain>/corrupted/" could
     not be expressed at either. A domain with a space in it is a real one. *)
  let ck = "cba685e06d3e500f-293331628d03f29b" in
  let chunk d = "tsync/" ^ d ^ "/chunks/" ^ String.sub ck 0 3 ^ "/" ^ ck in
  List.iter
    (fun d ->
      let cp = "tsync/" ^ d ^ "/chunks/" in
      check ("domain of " ^ d) (Chunk_layout.domain_of ~chunk_prefix:cp = d);
      check ("marker for " ^ d)
        (Chunk_layout.marker_key (chunk d)
        = Some ("tsync/corrupted/" ^ d ^ "/" ^ String.sub ck 0 3 ^ "/" ^ ck));
      check
        ("corrupted prefix for " ^ d)
        (Chunk_layout.corrupted_prefix ~chunk_prefix:cp
        = "tsync/corrupted/" ^ d ^ "/");
      check ("job key for " ^ d)
        (Chunk_layout.verify_job_key ~chunk_prefix:cp "abc"
        = "tsync/verify-jobs/" ^ d ^ "/abc"))
    ["dom"; "Jellyfin Media"];
  let marker = Option.get (Chunk_layout.marker_key (chunk "Jellyfin Media")) in
  check "a marker is one" (Chunk_layout.is_marker_key marker);
  check "and names its chunk" (Chunk_layout.chunk_key_of_marker marker = ck);
  (* The non-recursion guard, in code rather than only in a filter. *)
  check "a marker earns none of its own" (Chunk_layout.marker_key marker = None);
  check "nor does the space a collection empties"
    (Chunk_layout.marker_key
       ("tsync/d/chunks.from/" ^ String.sub ck 0 3 ^ "/" ^ ck)
    = None);
  (* A manifest is filed under the hash of its own name, so it is spelled
     exactly like a chunk key: membership is the prefix, never the shape. *)
  check "nor a manifest"
    (Chunk_layout.marker_key
       ("tsync/d/manifests/" ^ String.sub ck 0 3 ^ "/" ^ ck)
    = None);
  (* A marker under an empty domain would sit at a prefix nothing lists, every
     reader building that prefix from a domain name; both sides refuse it. *)
  check "an empty domain is not a chunk key's home"
    (Chunk_layout.marker_key ("tsync//chunks/" ^ String.sub ck 0 3 ^ "/" ^ ck)
    = None);
  check "a shard directory is not a marker"
    (not (Chunk_layout.is_marker_key "tsync/corrupted/dom/abc/"));
  (* The keys a delete request is filed under are pinned against the Python that
     parses them in {!tests/unit/gc_job}; here only the body, whose two spellings
     never meet on real input — OCaml writes it and the function reads it. *)
  let keys = [chunk "dom"; chunk "Jellyfin Media"] in
  check "a request body round trips"
    (Discard_job.decode (Discard_job.encode keys) = keys);
  check "and an empty one carries nothing"
    (Discard_job.decode (Discard_job.encode []) = []);
  print_endline "layout ok"
