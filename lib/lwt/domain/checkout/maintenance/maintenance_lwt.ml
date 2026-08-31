(* The file layer's sweeps, bound to this process's filesystem, pools and
   clock. Assembly only -- what each one does is in Tsync_checkout_maintenance,
   and what schedules them is the driver. *)

include Sweep

(* A sweep, named and with its trigger stated. The type is here rather than
   beside {!Sweep.trigger} because a task is a promise, and what runs one is
   this process. *)
type task = {
  name : string;
  (* Several, because a sweep can be owed for more than one reason and running
     it on only the loudest of them is how a case goes missing: the chunk cap is
     nudged after an upload, but a process that only reads still grows the store
     and would never enforce it at all. *)
  triggers : Sweep.trigger list;
  run : unit -> Sweep.swept Lwt.t;
}

module Files = struct
  include Io_lwt.Fs
  include Cache_layout_lwt
end

module Temp_files = Temp_files.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Bounded)

module Staged_orphans =
  Staged_orphans.Over (Io_lwt.Core) (Files) (Staged_lwt.Manifest)

module Chunk_cap = Chunk_cap.Make (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry)
