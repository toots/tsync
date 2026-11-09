(* Staged.read_whole: the range asked for, clipped at the end of the body, and
   empty past it. *)

open Tsync_checkout
module Bigstring = Tsync_core.Bigstring

let () =
  let cache_root = Filename.temp_dir "tsync-staged-whole" "" in
  let staged = Staged.create ~cache_root (Tsync_core.Domain_name.v "docs") in
  let path = Staged.whole_path staged "0123456789abcdef" in
  Tsync_core.Fs.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
      output_string oc (String.init 100_000 (fun i -> Char.chr (i mod 251))));
  let show what ~off ~len =
    let b = Staged.read_whole staged "0123456789abcdef" ~off ~len in
    let n = Bigstring.length b in
    let first = if n > 0 then Char.code (Bigarray.Array1.get b 0) else -1 in
    let last =
      if n > 0 then Char.code (Bigarray.Array1.get b (n - 1)) else -1
    in
    Printf.printf "%s: off %d len %d -> %d bytes, first %d, last %d\n" what off
      len n first last
  in
  show "inside" ~off:4096 ~len:8192;
  show "unaligned" ~off:1000 ~len:10;
  show "clipped at the end" ~off:96_000 ~len:8192;
  show "past the end" ~off:100_000 ~len:8192;
  show "empty" ~off:0 ~len:0;
  Sys.remove path
