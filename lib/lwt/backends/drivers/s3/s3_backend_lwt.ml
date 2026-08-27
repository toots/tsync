(* The S3 store on Lwt: the API's own Lwt deferred, and where it registers
   itself. *)
include
  S3_backend.Over (Io_lwt.Core) (Aws_s3_lwt.Io) (Retry_lwt) (Io_lwt.Bounded)
    (Io_lwt.Clock)

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("s3 backend: missing field: " ^ key)
  in
  Backend_lwt.register ~spec "s3" (fun get ->
      (* [None] rather than [Some false]: unset must leave the store's own
         default alone. *)
      let unsigned_payload =
        if Field_spec.bool ~default:false (get "unsignedPayload") then Some true
        else None
      in
      let share_url =
        match get "shareUrl" with Some "" | None -> None | s -> s
      in
      make ?endpoint:(get "endpoint") ?unsigned_payload ?share_url
        ~bucket:(req get "bucket") ~region:(req get "region")
        ~access_key_id:(req get "accessKeyId")
        ~secret_access_key:(req get "secretAccessKey")
        ())
