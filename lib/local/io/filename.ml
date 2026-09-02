include Stdlib.Filename

(* Shares the [.tsync-] sentinel with the other reserved names, so a listing
   reads it as internal rather than as someone's file. *)
let temp_prefix = ".tsync-tmp-"
let temp_seq = ref 0

(* Unique per process and per call rather than [path ^ ".tmp"]: two writers of
   one path would otherwise share a temp file and the loser's rename would fail
   ENOENT. *)
let temp_path path =
  incr temp_seq;
  Stdlib.Filename.concat
    (Stdlib.Filename.dirname path)
    (Printf.sprintf "%s%d-%d.tmp" temp_prefix (Unix.getpid ()) !temp_seq)

(* The prefix carries the test, not the ".tmp" suffix: as a suffix test in
   another module this matched user files too, and the walkers hid and deleted
   them, so a Syncthing folder downloading ".syncthing.<name>.tmp" re-fetched
   the same gigabytes forever. *)
let is_temp_name name =
  String.starts_with ~prefix:temp_prefix name
  && Stdlib.Filename.check_suffix name ".tmp"

let temp_owner name =
  if not (is_temp_name name) then None
  else (
    let rest =
      String.sub name
        (String.length temp_prefix)
        (String.length name - String.length temp_prefix)
    in
    match String.index_opt rest '-' with
      | None -> None
      | Some i -> int_of_string_opt (String.sub rest 0 i))
