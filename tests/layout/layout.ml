(* Placement rules for the two sharded stores. Both trade a flat directory for a
   shard, and both are only safe while the shard leaves the ordering and identity
   readers depend on undisturbed. *)

let check name cond = if not cond then failwith ("layout: " ^ name)

(* Fixed epoch milliseconds rather than a run-time calendar:
   [Journal.relative_path] shards by UTC, so going through local time would file
   entries in a different month depending on where the test ran. *)
let entry ms = Printf.sprintf "%013Ld-client" ms
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
  check "month shard" (Journal.relative_path jan = "2027-01/" ^ jan);
  check "year boundary" (Journal.relative_path dec = "2026-12/" ^ dec);
  check "entry key survives"
    (Filename.basename (Journal.relative_path feb) = feb);
  check "entry keys ordered" (dec < jan && jan < feb);
  (* An entry key is not itself a path under the journal prefix: a lookup built
     by concatenation lands somewhere no entry was ever written and reports the
     entry missing. Go through {!File_store.journal_entry_published}. *)
  check "entry key is not the object path" (Journal.relative_path feb <> feb);
  check "sharded paths ordered in the same order"
    (Journal.relative_path dec < Journal.relative_path jan
    && Journal.relative_path jan < Journal.relative_path feb);
  print_endline "layout ok"
