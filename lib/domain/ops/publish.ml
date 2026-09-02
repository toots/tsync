(* Putting something into the domain, the way an import and a copy both do it:
   a file, a symlink or a folder is written to the store and the mirror, and
   announced through a journal entry batched with its neighbours. *)

(* A deferred replica queues an entry behind the objects it names, so covering a
   whole run with one entry hides everything the run published from that
   replica's readers until its backlog drains; and a count alone bounds nothing
   a reader can feel, so a batch is published by age as well. *)
let entry_ops = 2000
let entry_age = 10.

module Over
    (Io : Io.S)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t)
    (Spool : Listing.SPOOL with type 'a io := 'a Io.t)
    (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t)
    (Objects : Remote.OVER with type 'a io := 'a Io.t)
    (Store : Store.INODE with type 'a io := 'a Io.t)
    (Journal_store : File_store.OVER with type 'a io := 'a Io.t)
    (Mirror : Manifests.OVER with type 'a io := 'a Io.t)
    (Checkout : Checkout.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module R = Objects.Make (C)
    module St = Store.Make (C)
    module Js = Journal_store.Make (C)
    module Mf = Mirror.Make (C)
    module Ck = Checkout.Make (C)

    (* Journal ops spooled to disk as they accumulate, so a run holds nothing
       that grows with the tree, and published in batches so peers see a long
       run while it goes. Every add is in sequence: an op appended in parallel
       would land in a spool already sealed. *)
    module Batch = struct
      type t = {
        dir : string;
        ops : int;
        age : float;
        mutable spool : Spool.t;
        mutable count : int;
        mutable published_at : float;
      }

      let create ?(ops = entry_ops) ?(age = entry_age) ~dir () =
        let+ spool = Spool.create ~dir ~name:"journal" in
        { dir; ops; age; spool; count = 0; published_at = Unix.gettimeofday () }

      let publish t =
        if t.count = 0 then return_unit
        else (
          let full = t.spool in
          let* fresh = Spool.create ~dir:t.dir ~name:"journal" in
          t.spool <- fresh;
          t.count <- 0;
          t.published_at <- Unix.gettimeofday ();
          Io.finalize
            (fun () ->
              let* body = Spool.seal full in
              let* entry_key = Js.write_journal_entry_body body in
              Js.bump_cursor entry_key)
            (fun () -> Spool.drop full))

      (* One op at a time, so a whole tree's worth handed over at once is split
         the same as a file arriving per call. *)
      let add t ops =
        iter_s
          (fun op ->
            let* () = Spool.append t.spool (Journal.encode [op]) in
            t.count <- t.count + 1;
            if
              t.count >= t.ops
              || Unix.gettimeofday () -. t.published_at >= t.age
            then publish t
            else return_unit)
          ops

      let drop t = Spool.drop t.spool
    end

    let file ?(on_progress = fun ~bytes:_ ~sent:_ -> ()) ~src_path key =
      let* st = Syscalls.stat src_path in
      let* chunk_size = R.chunk_size () in
      let* m =
        R.upload ~key ~src_path ~mtime:st.Unix.st_mtime ~chunk_size ~on_progress
          ()
      in
      let+ () = Mf.write key m in
      m

    (* No cache entry: a symlink has no file data. *)
    let symlink ~target ~mtime key =
      let name = Logical_key.leaf key in
      let m = Manifest.make_symlink ~name ~target ~mtime in
      let* () = St.put_manifest ~key ~data:(Manifest.body ~name m) in
      let+ () = Mf.write key m in
      m

    (* Answers the id the marker minted, which a peer resolves the folder by. *)
    let dir key =
      let* () = Ck.create_dir key in
      let* () = St.put_folder_marker ~key in
      Folder_ids.ensure_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        key
  end
end
