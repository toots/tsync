open Tsync_core
open Tsync_checkout
open Tsync_remote

module Make (C : Engine_ctx.S) = struct
  include Outbound.Make (C)

  (* What bulk publishers (import, rsync) share, in a submodule so its names
     never shadow the engine's. *)
  module Bulk = struct
    (* 05 §4.2 ENTRY_OPS / ENTRY_AGE. *)
    let entry_ops = 2000
    let entry_age = 10.

    (* 05 §4.3: the domain holds a key when the store has its manifest or this
       client holds it, published or staged. *)
    let exists rel = kind rel <> `Absent || store_manifest rel <> None

    let publish ?resend rel m =
      let pid = ensure_folder_id ~create:true (Names.parent_of rel) in
      let leaf = Names.leaf_of rel in
      R.publish ?resend ~parent:pid ~leaf m;
      let m = Manifest.rename m leaf in
      with_meta (fun () ->
          with_key rel (fun () -> Mirror.write_file ~own:true mirror rel m))

    let unchanged (a : Unix.stats) (b : Unix.stats) =
      a.st_size = b.st_size && a.st_mtime = b.st_mtime
      && a.st_ctime = b.st_ctime

    (* The stat is of the open descriptor, and taken again once every chunk is
       read: a file renamed or rewritten meanwhile is never published. *)
    let upload_file ?sent rel path =
      Fs.with_fd (Fs.openfile path [O_RDONLY]) (fun fd ->
          let st = Unix.fstat fd in
          let size = st.st_size and cs = R.chunk_size () in
          let read i =
            let len = if size = 0 then 0 else Chunking.length ~size ~cs i in
            let buf = Bigstring.create len in
            let n = Fs.pread_full fd buf ~boff:0 ~len ~off:(i * cs) in
            Bigstring.sub buf ~off:0 ~len:n
          in
          let m =
            R.upload_chunks ?sent ~name:(Names.leaf_of rel) ~size ~chunk_size:cs
              ~mtime:st.st_mtime (fun i -> Remote.Lazy (fun () -> read i))
          in
          let resend ck =
            let rec find i =
              if i >= m.count then None
              else if Chunk_key.equal (Manifest.key m i) ck then Some (read i)
              else find (i + 1)
            in
            find 0
          in
          if not (unchanged st (Unix.fstat fd)) then
            Fail.raise_ Fail.Local "%s changed while it was read" rel;
          publish ~resend rel m;
          size)

    let publish_link rel ~target ~mtime =
      publish rel (Manifest.symlink ~name:(Names.leaf_of rel) ~mtime target)

    (* A folder this client holds no id for is claimed now, so what goes
       beneath it can be published, and announced through the ordered
       metadata queue; [Ok false] when it was already held. *)
    let folder rel =
      match Mirror.kind mirror rel with
        | `File -> Error "a file holds this name in the domain"
        | `Dir when Mirror.folder_id mirror rel <> None -> Ok false
        | _ ->
            let id = ensure_folder_id ~create:true rel in
            with_meta (fun () ->
                record_owed [Op.Mkdir { path = rel; id = Some id }] ignore);
            Ok true

    (* durable-queue §7.3: a batch's record lists its items' ops before any of
       them runs, and is held until they ran; it is then rewritten to the ops
       of the items whose [run] answered that their store half happened, and
       handed to [queue]. Items a batch did not reach go to the next one.
       [admit] decides when a batch forms whether an item is published at
       all. *)
    let batches ?(narrate = Narrate.none) ~noun ~cancelled ~queue ~op ~admit
        ~run items =
      let rec go = function
        | [] -> ()
        | _ when cancelled () -> ()
        | todo ->
            let rec choose n acc = function
              | e :: rest when n < entry_ops ->
                  if admit e then choose (n + 1) (e :: acc) rest
                  else choose n acc rest
              | rest -> (List.rev acc, rest)
            in
            let chosen, rest = choose 0 [] todo in
            if chosen = [] then go rest
            else (
              let id, fd =
                Dqueue.Records.create_held ~mint wal
                  (Wal.encode
                     {
                       Wal.state = Prepared;
                       attempts = 0;
                       ops = List.map op chosen;
                       priors = [];
                       local_from = [];
                       fids = [];
                       last_error = None;
                     })
              in
              let started = Unix.gettimeofday () in
              let ran = ref [] in
              let rec step = function
                | [] -> []
                | left
                  when cancelled ()
                       || Unix.gettimeofday () -. started > entry_age ->
                    left
                | e :: rest ->
                    if run e then ran := e :: !ran;
                    step rest
              in
              (* Rewritten before the hold is released, so no rescan adopts the
                 full record in between; the rewrite ends the hold itself. *)
              let release () =
                let ran = List.rev !ran in
                let announces =
                  Fun.protect
                    ~finally:(fun () -> Unix.close fd)
                    (fun () ->
                      if List.length ran = List.length chosen then true
                      else if ran = [] then (
                        Dqueue.Records.complete wal id;
                        false)
                      else (
                        Dqueue.Records.update wal id (fun body ->
                            match Wal.decode body with
                              | Some r ->
                                  Wal.encode { r with ops = List.map op ran }
                              | None -> body);
                        true))
                in
                if announces then Dqueue.adopt queue id
              in
              let left = Fun.protect ~finally:release (fun () -> step chosen) in
              Narrate.say narrate "  announced a batch of %s"
                (Narrate.count (List.length !ran) noun);
              go (left @ rest))
      in
      go items
  end
end
