open Tsync_core
open Tsync_checkout
open Tsync_remote

module Make (C : Engine_ctx.S) = struct
  include Cycle.Make (C)

  (* What bulk publishers (import, rsync) share (05 §4.2), in a submodule so
     its names never shadow the engine's: each change is a local operation,
     and the run waits for the commit of the keys it [note]d. *)
  module Bulk = struct
    type run = Algebra.key list ref

    let run () : run = ref []
    let note (run : run) key = run := key :: !run
    let note_file run rel = note run (`File (place_of rel))

    let exists rel =
      match kind rel with
        | `Absent -> false
        | `Dir -> true
        | `File -> not (is_damaged (place_of rel))

    (* durable-queue §7.3: the chunks are on the main; the manifest becomes
       the key's local value, with its before-value. *)
    let install run rel (m : Manifest.t) =
      let m = Manifest.rename m (Names.leaf_of rel) in
      with_meta (fun () ->
          with_key rel (fun () ->
              begin_change rel;
              ignore (discard_edit rel);
              end_lineage rel;
              Mirror.write_file ~own:true mirror rel m;
              ignore (Mirror.ensure_file_id mirror rel);
              settle rel);
          Mutex.protect damaged_m (fun () ->
              Hashtbl.remove damaged (place_of rel));
          let op = Op.Put { path = rel; size = m.size } in
          feed ~fids:(note_fids [op]) [op]);
      note_file run rel;
      changed [rel];
      wake_cycle ()

    let unchanged (a : Unix.stats) (b : Unix.stats) =
      a.st_size = b.st_size && a.st_mtime = b.st_mtime
      && a.st_ctime = b.st_ctime

    (* The stat is of the open descriptor, and taken again once every chunk is
       read: a file renamed or rewritten meanwhile is never installed. *)
    let upload_file ?sent run rel path =
      Fs.with_fd (Fs.openfile path [O_RDONLY]) (fun fd ->
          let st = Unix.fstat fd in
          let size = st.st_size and cs = R.chunk_size () in
          let read i =
            let len = if size = 0 then 0 else Chunking.length ~size ~cs i in
            let buf = Bigstring.create len in
            let n = Fs.pread_full fd buf ~boff:0 ~len ~off:(i * cs) in
            Bigstring.sub buf ~off:0 ~len:n
          in
          (* A short chunk and a changed stat are one condition, reported
             one way whichever notices first. *)
          let changed () =
            Fail.raise_ Fail.Local "%s changed while it was read" rel
          in
          let m =
            try
              R.upload_chunks ?sent ~name:(Names.leaf_of rel) ~size
                ~chunk_size:cs ~mtime:st.st_mtime (fun i ->
                  Remote.Lazy (fun () -> read i))
            with Remote.Source_changed _ -> changed ()
          in
          if not (unchanged st (Unix.fstat fd)) then changed ();
          install run rel m;
          size)

    let install_link run rel ~target ~mtime =
      install run rel (Manifest.symlink ~name:(Names.leaf_of rel) ~mtime target)

    (* [Ok false] when the folder was already there. *)
    let folder run rel =
      match Mirror.kind mirror rel with
        | `File -> Error "a file holds this name in the domain"
        | `Dir -> Ok false
        | `Absent ->
            mkdir rel ~exclusive:false;
            Option.iter (fun id -> note run (`Folder id)) (folder_id_of rel);
            Ok true

    let is_pending : Algebra.key -> bool = function
      | `File p -> Sync_state.before_file sync_state p <> None
      | `Folder i -> Sync_state.before_folder sync_state i <> None

    (* 05 §4.2: push, and return once none of the run's keys is pending; how
       many are left when the run is cancelled first. *)
    let await ?(cancelled = Fun.const false) (run : run) =
      let left () = List.length (List.filter is_pending !run) in
      let rec loop () =
        if left () = 0 || cancelled () then left ()
        else (
          let committed =
            try (run_cycle ()).committed with
              | (Stop.Stopping | Rt.Cancelled) as e -> raise e
              | e ->
                  Log.info "waiting to commit: %s" (Printexc.to_string e);
                  0
          in
          if committed = 0 && left () > 0 then Stop.sleep Cycle.retry_floor;
          loop ())
      in
      loop ()
  end
end
