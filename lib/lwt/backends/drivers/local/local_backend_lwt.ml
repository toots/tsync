(* The store on this machine's filesystem, and the registration that makes it
   reachable by name. The registry is the instance's, so this is where a driver
   announces itself. *)
module Wall = struct
  let now = Unix.gettimeofday
end

include
  Local_backend.Over (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry) (Io_lwt.Bounded)
    (Bigstring_lwt)
    (Wall)
    (Io_lwt.Clock)

let () =
  Backend_lwt.register ~spec "local" (fun get ->
      let root =
        match get "path" with
          | Some p -> p
          | None -> failwith "local backend: missing field: path"
      in
      (* Costs one read back per chunk written, usually from page cache. Off is
         for a store whose throughput matters more than knowing early — the
         chunks are still checked wherever else they land. *)
      let verify_writes = Field_spec.bool ~default:true (get "verifyWrites") in
      make ~verify_writes ~root ())
