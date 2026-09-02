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

(* Running one, the same way wherever it is run from -- the driver, a command,
   a test. A sweep that fails is logged and does not take its siblings with it,
   and one that collected something says so rather than answering into the
   void. *)
let run_task t =
  let open Lwt.Syntax in
  Lwt.catch
    (fun () ->
      let+ swept = t.run () in
      if swept.files > 0 then
        Log.info "%s: collected %d file(s), %d byte(s)" t.name swept.files
          swept.bytes;
      swept)
    (fun exn ->
      Log.err "%s: %s" t.name (Printexc.to_string exn);
      Lwt.return nothing)

let has_trigger want t = List.mem want t.triggers

(* How long an unnamed staged body is left alone. A body is written before the
   sidecar that records it, so a young one nothing names may be a write still in
   progress, whatever process is making it. *)
let default_staged_grace = 3600.

(* How much journal history a client keeps for its own change feed. Past this an
   anchor cannot be bridged and whoever holds one re-lists, so the window is how
   long a frontend may be away and still catch up incrementally.

   The byte cap is the second bound the first one does not give: a busy domain
   can write a month of entries far larger than a quiet one writes in a year. *)
let applied_keep_bytes = 64 * 1024 * 1024

(* Shards are monthly, so nothing is collectable more often than that; running
   it daily is only so a long-lived process never has to be restarted to shed
   them. *)
let applied_prune_interval = 86_400.

(* The sweeps a domain owes that need nothing but its config. Separate from the
   ones the engine adds because a command can run these without building a
   serving stack, and because they are the whole of what [tsync cache --prune]
   does -- which is what keeps the command and the task list from drifting. *)
module Domain (C : Conf_lwt.S) = struct
  module Temp = Temp_files.Make (C)
  module Orphans = Staged_orphans.Make (C)

  let tasks ?(staged_grace = default_staged_grace) () =
    [
      { name = "mirror temp files"; triggers = [`On_demand]; run = Temp.run };
      {
        name = "staged orphans";
        triggers = [`On_demand];
        run =
          (fun () ->
            Orphans.run ~cutoff:(Unix.gettimeofday () -. staged_grace) ());
      };
      {
        name = "applied journal entries";
        (* Periodic as well as on demand: this is the one sweep whose growth
           comes from the domain changing rather than from anything a command
           does, so a daemon nobody prunes by hand still sheds it. *)
        triggers = [`On_demand; `Periodic applied_prune_interval];
        run =
          (fun () ->
            let open Lwt.Syntax in
            let+ files, bytes =
              Applied_entries.prune ~cache_root:C.cache_root
                ~domain_name:C.domain_name ~keep_days:Applied_entries.keep_days
                ~keep_bytes:applied_keep_bytes
            in
            { files; bytes });
      };
    ]
end
