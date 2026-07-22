open Lwt.Syntax

module Make (F : File.S) = struct
  let table : (string, int * Lwt_unix.file_descr) Hashtbl.t = Hashtbl.create 64

  (* Opening a fresh fd is asynchronous, so two concurrent [acquire]s on the
     same not-yet-open key could otherwise both see it absent and both open
     it; serialize acquire/release through one mutex to keep the table and
     its refcounts consistent. *)
  let mutex = Lwt_mutex.create ()

  let acquire key =
    Lwt_mutex.with_lock mutex (fun () ->
        match Hashtbl.find_opt table key with
          | Some (n, fd) ->
              Hashtbl.replace table key (n + 1, fd);
              Lwt.return_unit
          | None ->
              let* fd =
                Lwt_unix_retry.openfile (F.local_path key)
                  [Unix.O_RDWR; Unix.O_CREAT]
                  0o644
              in
              Hashtbl.replace table key (1, fd);
              Lwt.return_unit)

  let release key =
    Lwt_mutex.with_lock mutex (fun () ->
        match Hashtbl.find_opt table key with
          | None -> Lwt.return_unit
          | Some (n, fd) ->
              let n' = n - 1 in
              if n' <= 0 then (
                Hashtbl.remove table key;
                Lwt_unix_retry.close fd)
              else (
                Hashtbl.replace table key (n', fd);
                Lwt.return_unit))

  let find key = Option.map snd (Hashtbl.find_opt table key)
end
