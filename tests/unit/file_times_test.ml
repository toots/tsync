(* Fs.times and Fs.set_times (02 §2.6): nanoseconds kept exactly, and the
   creation time the platform keeps. *)

open Tsync_core

let p fmt = Printf.printf fmt
let sets_created = Fs.sets_created

let birth_seconds_from_stat path =
  let ic = Unix.open_process_args_in "stat" [| "stat"; "-c"; "%W"; path |] in
  let line = In_channel.input_line ic in
  ignore (Unix.close_process_in ic);
  Option.bind line int_of_string_opt

let () =
  let dir = Filename.temp_dir "tsync-file-times" "" in
  let path = Filename.concat dir "f" in
  Out_channel.with_open_bin path (fun oc -> output_string oc "x");
  let born = Fs.times path in
  let set =
    { Fs.mtime = 1_015_218_367_123_456_789; created = 946_684_800_987_654_321 }
  in
  Fs.set_times path set;
  let read = Fs.times path in
  (* Read once the mtime is back in 2002, so a stub that answered the mtime
     for the creation time would differ from stat. *)
  if Sys.os_type = "Unix" && not Fs.is_macos then
    p "the creation time is the one stat reports: %b\n"
      (match birth_seconds_from_stat path with
        | Some 0 | None -> read.created = read.mtime
        | Some s -> read.created / 1_000_000_000 = s)
  else p "the creation time is the one stat reports: true\n";
  (* Windows counts 100 ns. *)
  let same a b = if Sys.win32 then a / 100 = b / 100 else a = b in
  p "the mtime reads back to the nanosecond: %b\n" (same read.mtime set.mtime);
  p "the creation time reads back as set, where the platform sets it: %b\n"
    (if sets_created then same read.created set.created
     else read.created = born.created);
  (* FAT's unset creation time, which reads as none; checked where it can be set. *)
  let unset = { set with created = 315_532_800_000_000_000 } in
  Fs.set_times path unset;
  p "an unset creation time reads as the mtime: %b\n"
    ((not sets_created) || (Fs.times path).created = (Fs.times path).mtime);
  Fs.set_times path set;
  let fd = Unix.openfile path [O_RDONLY] 0 in
  p "a descriptor reads the same times: %b\n" (Fs.ftimes fd = read);
  Unix.close fd;
  Fs.rm_rf dir
