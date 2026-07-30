(* Placement rules for the two sharded stores. Both trade a flat directory for a
   shard, and both are only safe because of a property that is easy to break:
   the shard must not disturb the ordering or the identity readers depend on. *)

let check name cond = if not cond then failwith ("layout: " ^ name)

let ms_of ~y ~m ~d =
  let t, _ =
    Unix.mktime
      {
        Unix.tm_year = y - 1900;
        tm_mon = m - 1;
        tm_mday = d;
        tm_hour = 12;
        tm_min = 0;
        tm_sec = 0;
        tm_wday = 0;
        tm_yday = 0;
        tm_isdst = false;
      }
  in
  (* mktime reads local time; shift back so the entry lands on the intended day
     in UTC, which is what [Journal.relative_path] formats. *)
  Int64.of_float ((t -. fst (Unix.mktime (Unix.gmtime 0.))) *. 1000.)

let entry ~y ~m ~d = Printf.sprintf "%013Ld-client" (ms_of ~y ~m ~d)

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
  let dec = entry ~y:2026 ~m:12 ~d:31 in
  let jan = entry ~y:2027 ~m:1 ~d:1 in
  let feb = entry ~y:2027 ~m:2 ~d:1 in
  check "month shard" (Journal.relative_path jan = "2027-01/" ^ jan);
  check "year boundary" (Journal.relative_path dec = "2026-12/" ^ dec);
  check "entry key survives"
    (Filename.basename (Journal.relative_path feb) = feb);
  check "entry keys ordered" (dec < jan && jan < feb);
  check "sharded paths ordered in the same order"
    (Journal.relative_path dec < Journal.relative_path jan
    && Journal.relative_path jan < Journal.relative_path feb);
  print_endline "layout ok"
