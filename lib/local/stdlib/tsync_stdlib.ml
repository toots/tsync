(** [Stdlib]'s and [Sys]'s file operations, shadowed to retry past [EINTR].
    Meant to be opened, so a call site keeps the names and the types it had and
    nothing below has to remember this exists.

    A shim rather than a note telling everyone to be careful, because the
    failure is invisible from up here. [Sys.set_signal] installs handlers
    without [SA_RESTART] -- and [Lwt_main.run] installs one for [SIGCHLD]
    whether or not anything waits on a child -- so from the first turn of the
    loop every blocking syscall in the process can be interrupted.
    [runtime/sys.c] then never retries: it reports the interruption as
    [Sys_error "<path>: Interrupted system call"], a string, which no handler
    for [Unix_error (EINTR, _, _)] can match. One of those, out of [open_in] on
    the client uuid, killed the daemon's event loop.

    [Sys.file_exists] is worse and is why it is rebuilt on [Unix.stat] here: it
    answers [false] for any failure at all, so an interrupted [stat] reads as
    "no such file" and the caller goes off and does whatever it does about one.

    Everything [runtime/sys.c] raises for is here. Channel reads and writes are
    not, because [runtime/io.c] already loops on [EINTR]. Nor are
    [In_channel]/[Out_channel], which no caller here uses; they open files too,
    so reach for {!Eintr.retry} if that changes.

    No [.mli]: the surface is [Stdlib]'s, and a signature cannot restate it --
    the operations shadowed below are [external]s in [sys.mli]. *)

module Eintr = struct
  (* Both spellings of the same interruption. The [Sys_error] message is
     [strerror]'s, so it is compared against [Unix.error_message] rather than a
     literal: the same C string on both sides, whatever the platform says. *)
  let interrupted = function
    | Unix.Unix_error (Unix.EINTR, _, _) -> true
    | Sys_error msg ->
        let suffix = Unix.error_message Unix.EINTR in
        let extra = String.length msg - String.length suffix in
        extra >= 0 && String.sub msg extra (String.length suffix) = suffix
    | _ -> false

  let rec retry f =
    match f () with v -> v | exception e when interrupted e -> retry f
end

let open_in path = Eintr.retry (fun () -> Stdlib.open_in path)
let open_in_bin path = Eintr.retry (fun () -> Stdlib.open_in_bin path)

let open_in_gen flags perm path =
  Eintr.retry (fun () -> Stdlib.open_in_gen flags perm path)

let open_out path = Eintr.retry (fun () -> Stdlib.open_out path)
let open_out_bin path = Eintr.retry (fun () -> Stdlib.open_out_bin path)

let open_out_gen flags perm path =
  Eintr.retry (fun () -> Stdlib.open_out_gen flags perm path)

let close_in ic = Eintr.retry (fun () -> Stdlib.close_in ic)
let close_out oc = Eintr.retry (fun () -> Stdlib.close_out oc)

module Sys = struct
  include Stdlib.Sys

  (* [stat] and [false] for every other failure, which is what
     [Stdlib.Sys.file_exists] is; the only difference is that a signal has
     stopped counting as one. *)
  let file_exists path =
    match Eintr.retry (fun () -> Unix.stat path) with
      | (_ : Unix.stats) -> true
      | exception Unix.Unix_error _ -> false

  let is_directory path = Eintr.retry (fun () -> Stdlib.Sys.is_directory path)

  let is_regular_file path =
    Eintr.retry (fun () -> Stdlib.Sys.is_regular_file path)

  let remove path = Eintr.retry (fun () -> Stdlib.Sys.remove path)
  let rename src dst = Eintr.retry (fun () -> Stdlib.Sys.rename src dst)
  let readdir path = Eintr.retry (fun () -> Stdlib.Sys.readdir path)
  let mkdir path perm = Eintr.retry (fun () -> Stdlib.Sys.mkdir path perm)
  let rmdir path = Eintr.retry (fun () -> Stdlib.Sys.rmdir path)
  let chdir path = Eintr.retry (fun () -> Stdlib.Sys.chdir path)
  let getcwd () = Eintr.retry (fun () -> Stdlib.Sys.getcwd ())
end
