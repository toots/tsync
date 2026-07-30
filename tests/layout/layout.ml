(* Placement rules for the two sharded stores. Both trade a flat directory for a
   shard, and both are only safe because of a property that is easy to break:
   the shard must not disturb the ordering or the identity readers depend on. *)

let check name cond = if not cond then failwith ("layout: " ^ name)

(* Fixed instants, in epoch milliseconds, rather than anything derived from a
   calendar at run time: [Journal.relative_path] shards by UTC, so a test that
   went through local time would put its entries in a different month depending
   on where it ran. *)
let entry ms = Printf.sprintf "%013Ld-client" ms
let dec_31 = entry 1798718400000L (* 2026-12-31T12:00:00Z *)
let jan_01 = entry 1798804800000L (* 2027-01-01T12:00:00Z *)
let feb_01 = entry 1801483200000L (* 2027-02-01T12:00:00Z *)

let () =
  (* Chunks: the key is unchanged and recoverable, which every listing-side
     caller (expire's sweep, the test dumps) relies on. *)
  let k = "abbd5be7f7f1ea08-164c4bd493e0e119" in
  check "chunk shard" (Chunk_layout.relative_path k = "abb/" ^ k);
  check "chunk key survives"
    (Filename.basename (Chunk_layout.relative_path k) = k);
  check "short key" (Chunk_layout.relative_path "ab" = "_/ab");

  (* Journal: entries are applied in the order a listing sorts them, so the
     sharded path must sort the same way the bare entry keys do — including
     across a month and a year boundary, where the shard changes. *)
  let dec = dec_31 and jan = jan_01 and feb = feb_01 in
  check "month shard" (Journal.relative_path jan = "2027-01/" ^ jan);
  check "year boundary" (Journal.relative_path dec = "2026-12/" ^ dec);
  check "entry key survives"
    (Filename.basename (Journal.relative_path feb) = feb);
  check "entry keys ordered" (dec < jan && jan < feb);
  check "sharded paths ordered in the same order"
    (Journal.relative_path dec < Journal.relative_path jan
    && Journal.relative_path jan < Journal.relative_path feb);
  print_endline "layout ok"
