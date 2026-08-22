(* This client's unpublished bytes: the staged bodies a write lands in, and the
   whole files a frontend hands over entire.

   The only copy there is until an upload publishes them, which is why nothing
   here is reclaimable and the cap next door cannot see it. *)

open Lwt.Syntax

(* What the staged half needs of the cache: read a published chunk it is
   overwriting part of, and hand a finished body over to be published. *)
module type Cache = sig
  val read_into :
    group:Chunk_group.t ->
    index:int ->
    Local_io.buffer ->
    chunk_off:int ->
    Chunk_cache.served Lwt.t

  val link_in : src:string -> group:Chunk_group.t -> bool Lwt.t
end

module Make (C : Conf.S) (Cache : Cache) = struct
  let path uuid =
    Filename.concat
      (Cache_layout.staged_chunks_dir ~cache_root:C.cache_root C.domain_name)
      uuid

  (* Sparse, so the part of a group nobody has written costs no disk. *)
  let len_of ~uuid =
    Lwt.catch
      (fun () ->
        let+ st = Lwt_unix_retry.LargeFile.stat (path uuid) in
        Some (Int64.to_int st.Unix.LargeFile.st_size))
      (fun _ -> Lwt.return_none)

  let ensure ~uuid ~len =
    let p = path uuid in
    let* () = Fs_util.ensure_parent p in
    let* have = len_of ~uuid in
    match have with
      | Some n when n >= len -> Lwt.return_unit
      | _ ->
          let* fd =
            Lwt_unix_retry.openfile p [Unix.O_WRONLY; Unix.O_CREAT] 0o644
          in
          Lwt.finalize
            (fun () -> Lwt_unix_retry.LargeFile.ftruncate fd (Int64.of_int len))
            (fun () -> Lwt_unix_retry.close fd)

  let resize ~uuid ~len =
    let* fd = Lwt_unix_retry.openfile (path uuid) [Unix.O_WRONLY] 0o644 in
    Lwt.finalize
      (fun () -> Lwt_unix_retry.LargeFile.ftruncate fd (Int64.of_int len))
      (fun () -> Lwt_unix_retry.close fd)

  let write ~uuid buf ~offset =
    Local_io.write (path uuid) buf ~offset:(Int64.of_int offset)

  let read_into ~uuid buf ~offset =
    Local_io.read (path uuid) buf ~offset:(Int64.of_int offset)

  (* Regrouping: the same bytes under a body that holds the whole group. *)
  let copy ~src ~src_off ~dst ~dst_off ~len =
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
    let* n = read_into ~uuid:src buf ~offset:src_off in
    let+ (_ : int) =
      write ~uuid:dst (Bigarray.Array1.sub buf 0 n) ~offset:dst_off
    in
    ()

  let forget ~uuid = Fs_util.unlink_quiet (path uuid)

  (* For a write not replacing all of a published chunk. The copy is the price of
     immutable content-addressed chunks. *)
  let copy_chunk ~group ~index ~uuid ~offset =
    let len = Chunk_group.size group index in
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
    let* served = Cache.read_into ~group ~index buf ~chunk_off:0 in
    let+ (_ : int) =
      write ~uuid (Bigarray.Array1.sub buf 0 served.Chunk_cache.bytes) ~offset
    in
    ()

  (* Publish by giving the same bytes a second name under the cache, which is
     what the group layout of a staged body is for.

     The copy path fails a member whose length disagrees with the manifest
     ({!Chunk_cache.put_group}); the link path publishes the body whole, so the
     same disagreement has to stop it here or it reaches the store under a name
     derived from bytes it does not hold. *)
  let link_group ~uuid ~len ~group =
    if len <> Chunk_group.bytes group then Lwt.return_false
    else
      Lwt.catch
        (fun () ->
          (* Inside the guard: a promotion replayed after the body was dropped
             finds nothing to resize, and writing the group is the answer. *)
          let* () = resize ~uuid ~len in
          Cache.link_in ~src:(path uuid) ~group)
        (fun _ -> Lwt.return_false)

  (* A frontend handing back a complete file (as the FileProvider extension
     always does) gets it adopted as-is: one file, no chunk split. *)

  let whole_path uuid =
    Filename.concat
      (Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name)
      uuid

  (* A rename on one filesystem, which is the point of this path; a copy across
     two. *)
  let adopt_whole ~src ~uuid =
    let dst = whole_path uuid in
    let* () = Fs_util.ensure_parent dst in
    Lwt.catch
      (fun () -> Lwt_unix_retry.rename src dst)
      (function
        | Unix.Unix_error (Unix.EXDEV, _, _) ->
            let* () = Fs_util.copy_file ~src ~dst in
            Fs_util.unlink_quiet src
        | exn -> Lwt.fail exn)

  let whole_read_into ~uuid buf ~offset =
    Local_io.read (whole_path uuid) buf ~offset

  let whole_forget ~uuid = Fs_util.unlink_quiet (whole_path uuid)
end
