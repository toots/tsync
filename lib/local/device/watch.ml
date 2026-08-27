(* The directory, never the file: an object here is written to a temp name and
   renamed into place, so a watch on the object's own name follows an inode that
   is unlinked a moment later.

   Descriptors rather than one, because kqueue watches an open file rather than
   a path and the directory's own descriptor is what holds the registration.
   The head is the one to wait on; the rest are along for the closing. *)

type t = Unix.file_descr array

external open_watch : string -> t = "tsync_watch_open_dir"
external drain_events : Unix.file_descr -> unit = "tsync_watch_drain"

let open_dir dir = try Some (open_watch dir) with Unix.Unix_error _ -> None
let fd watcher = watcher.(0)
let drain watcher = try drain_events watcher.(0) with Unix.Unix_error _ -> ()

let close watcher =
  Array.iter
    (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())
    watcher
