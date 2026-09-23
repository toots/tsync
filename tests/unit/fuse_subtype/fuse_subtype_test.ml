(* The configured subtype is spliced into FUSE's [-o] list, so anything that
   would read as an option of its own is refused up front. *)

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if ok then Printf.printf "  ok   %s\n" name
  else (
    incr failures;
    Printf.printf "  FAIL %s\n" name)

let refused value =
  match Fuse_frontend.mount_subtype (Some value) with
    | _ -> false
    | exception Failure _ -> true

let () =
  check "an absent subtype is sshfs" (Fuse_frontend.mount_subtype None = "sshfs");
  check "a blank subtype is sshfs"
    (Fuse_frontend.mount_subtype (Some "") = "sshfs");
  check "a name is kept" (Fuse_frontend.mount_subtype (Some "tsync") = "tsync");
  check "a comma is refused" (refused "sshfs,allow_other");
  check "an equals sign is refused" (refused "sshfs=x");
  check "a space is refused" (refused "ssh fs");
  Printf.printf "\n%d/%d checks passed\n" (!checks - !failures) !checks;
  exit (if !failures = 0 && !checks > 0 then 0 else 1)
