(* The kernel publishes what the device will take, so this is measured rather
   than inferred.

   [device/queue_depth] is what the hardware accepts — 1 for a USB enclosure on
   Bulk-Only Transport, which is the protocol rather than a misreading.
   [queue/nr_requests] is the block layer's own queue, standing in when the first
   is absent, as it is for anything that is not a SCSI device. *)

let read_line_opt path =
  match open_in path with
    | ic ->
        let line = try Some (String.trim (input_line ic)) with _ -> None in
        close_in ic;
        line
    | exception _ -> None

(* The device holding [path], from /proc/self/mountinfo, which already carries
   the major:minor — steadier than decoding a [dev_t], whose layout is libc's
   business rather than ours.

   Longest mount point wins: /mnt/tsync has to beat / for a path inside it. *)
let device_of_path path =
  match open_in "/proc/self/mountinfo" with
    | exception _ -> None
    | ic ->
        let covers mount =
          mount = "/"
          || String.length path >= String.length mount
             && String.sub path 0 (String.length mount) = mount
        in
        let best = ref None in
        (try
           while true do
             match String.split_on_char ' ' (input_line ic) with
               | _ :: _ :: dev :: _ :: mount :: _ when covers mount ->
                   let better =
                     match !best with
                       | Some (m, _) -> String.length mount > String.length m
                       | None -> true
                   in
                   if better then best := Some (mount, dev)
               | _ -> ()
           done
         with End_of_file -> ());
        close_in ic;
        Option.map snd !best

(* A small multiple of the hardware depth: enough to keep the device fed while
   the next request is being prepared, not so much that requests pile up past
   what it can reorder. The ceiling stops a device reporting something enormous
   from being the only thing setting the bound. *)
let requests_for ~queue_depth = max 2 (min 64 (queue_depth * 4))

let max_concurrency path =
  let ( let* ) = Option.bind in
  let* dev = device_of_path path in
  let base = "/sys/dev/block/" ^ dev in
  (* A partition has no queue of its own; the disk it sits on does. *)
  let base =
    if Sys.file_exists (Filename.concat base "partition") then
      Filename.concat base ".."
    else base
  in
  let* depth =
    match read_line_opt (Filename.concat base "device/queue_depth") with
      | Some d -> int_of_string_opt d
      | None ->
          Option.bind
            (read_line_opt (Filename.concat base "queue/nr_requests"))
            int_of_string_opt
  in
  if depth > 0 then Some (requests_for ~queue_depth:depth) else None

external ficlone : Unix.file_descr -> Unix.file_descr -> bool = "tsync_ficlone"

(* [FICLONE] wants the destination open for writing where the mapping wants it
   read-only, which is what the second open in [clone] is for. *)
let ficlone_to dst ~src =
  let src_fd = Unix.openfile src [Unix.O_RDONLY] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close src_fd)
    (fun () ->
      let dst_fd =
        Unix.openfile dst [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close dst_fd)
        (fun () -> ficlone dst_fd src_fd))

let clone ~src =
  let dst = Filename.temp_path src in
  if ficlone_to dst ~src then Some (Tsync_io.Fs.open_and_unlink dst)
  else (
    (* The empty file [ficlone_to] opened is not a clone of anything. *)
    (try Unix.unlink dst with Unix.Unix_error _ -> ());
    None)
