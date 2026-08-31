(* How a byte range is cut into the chunks holding it.

   Every line carries the covering verdict beside the cut, because the cut alone
   reads as plausible whatever it says: what a caller depends on is that the
   pieces sit where the range asked, in order, once each, inside their own
   chunks. A snapshot of cuts nobody checked would pin a wrong answer as
   happily as a right one. *)

let show ps =
  if ps = [] then "(none)"
  else
    String.concat " "
      (List.map
         (fun p ->
           Printf.sprintf "#%d[%d,%d)@%d" p.Chunks.index p.Chunks.chunk_off
             (p.Chunks.chunk_off + p.Chunks.len)
             p.Chunks.dest)
         ps)

let covering ~chunk_size ~offset ps =
  let rec go pos = function
    | [] -> true
    | p :: rest ->
        let at =
          Chunks.offset_of ~chunk_size p.Chunks.index + p.Chunks.chunk_off
        in
        at = pos
        && p.Chunks.dest = pos - offset
        && p.Chunks.len > 0
        && p.Chunks.chunk_off + p.Chunks.len <= chunk_size
        && go (pos + p.Chunks.len) rest
  in
  if go offset ps then "covers" else "BROKEN"

let cut name ~chunk_size ~count ~offset ~length =
  let ps = Chunks.pieces ~chunk_size ~count ~offset ~length in
  Printf.printf "  %-28s chunk=%d count=%d [%d,%d) -> %s (%s)\n" name chunk_size
    count offset (offset + length) (show ps)
    (covering ~chunk_size ~offset ps)

let () =
  print_endline "=== a range is cut at the chunks holding it";
  cut "whole file" ~chunk_size:8 ~count:3 ~offset:0 ~length:24;
  cut "inside one chunk" ~chunk_size:8 ~count:3 ~offset:9 ~length:2;
  cut "across a boundary" ~chunk_size:8 ~count:3 ~offset:6 ~length:4;
  cut "aligned to the boundary" ~chunk_size:8 ~count:3 ~offset:8 ~length:8;
  cut "every chunk but the first" ~chunk_size:8 ~count:3 ~offset:5 ~length:19;

  print_endline "";
  print_endline "=== the chunk count is the end of what can be served";
  (* Short rather than an error: a caller learns the file ended by being given
     fewer bytes, which is what [pread] reports. *)
  cut "past the last chunk" ~chunk_size:8 ~count:2 ~offset:12 ~length:16;
  cut "starting past the last chunk" ~chunk_size:8 ~count:2 ~offset:16 ~length:8;
  cut "a file with no chunks" ~chunk_size:8 ~count:0 ~offset:0 ~length:8;

  print_endline "";
  print_endline "=== nothing to cut";
  cut "no length" ~chunk_size:8 ~count:3 ~offset:0 ~length:0;
  (* A symlink body carries no chunks and no size to cut, and arrives here as a
     chunk size of zero rather than as a special case at the caller. *)
  cut "no chunk size" ~chunk_size:0 ~count:3 ~offset:0 ~length:8
