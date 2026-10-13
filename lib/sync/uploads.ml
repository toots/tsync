open Tsync_core
open Tsync_remote
open Tsync_checkout

(* The upload queue (spec 04 §4.6, publication §4.2): chunks to the main and
   the edit marked Uploaded; the cycle commits it. *)
module Make (C : Engine_ctx.S) = struct
  include Local_ops.Make (C)

  let source path (e : Staged.edit) i =
    let len =
      if e.size = 0 then 0 else Chunking.length ~size:e.size ~cs:e.chunk_size i
    in
    match e.content with
      | Whole { body; _ } ->
          Remote.Lazy
            (fun () ->
              Fs.with_fd
                (Fs.openfile (Staged.whole_path staged body) [O_RDONLY])
                (fun fd ->
                  let buf = Bigstring.create len in
                  let n =
                    Fs.pread_full fd buf ~boff:0 ~len ~off:(i * e.chunk_size)
                  in
                  Bigstring.sub buf ~off:0 ~len:n))
      | Slots slots -> (
          match if i < Array.length slots then slots.(i) else Staged.Zero with
            | Staged.Inherit -> (
                match Mirror.manifest mirror path with
                  | Some base
                    when i < base.count
                         && Chunking.length ~size:base.size ~cs:base.chunk_size
                              i
                            = len ->
                      Remote.Stored (Manifest.key base i)
                  | _ ->
                      Remote.Lazy
                        (fun () ->
                          read_staged path e ~off:(i * e.chunk_size) ~len))
            | Zero ->
                let b = Bigstring.create len in
                Bigarray.Array1.fill b '\000';
                Remote.Bytes b
            | Staged { body; off } ->
                Remote.Lazy (fun () -> Staged.read_body staged body ~off ~len))

  (* 04 §4.6: chunks without the lock; the result is recorded under it only
     if the edit generation is still the one read. *)
  let run_upload _id (u : Local_ops.upload) ~cancel =
    match path_of u.file with
      | None -> ()
      | Some path -> (
          match
            with_key path (fun () -> (Staged.read staged path, generation path))
          with
            | `Unparseable, _ ->
                Fail.corrupt "%s: its staged manifest cannot be decoded" path
            | (`Absent | `Edit { state = Uploaded _; _ }), _ -> ()
            | `Edit e, g ->
                let m =
                  uploading path ~size:e.size (fun progress ->
                      R.upload_chunks ~cancel ~progress
                        ~name:(Names.leaf_of path) ~size:e.size
                        ~chunk_size:e.chunk_size ~mtime:e.mtime (source path e))
                in
                with_key path (fun () ->
                    if generation path <> g || Atomic.get cancel then
                      raise Rt.Cancelled;
                    (* An Uploaded edit with no before-value reads as
                       committed (publication §4.8 step 4). *)
                    Sync_state.harden sync_state (`File (place_of path));
                    Staged.write staged path { e with state = Uploaded m };
                    settle_uploaded path);
                wake_cycle ())
end
