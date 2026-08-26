(* The Google store on Lwt, and where it registers itself. The token POST is the
   one request that does not go through the shared client: it happens before
   there is a token to authorise it with. *)
module Post = struct
  let post ~headers ~body uri =
    let open Lwt.Syntax in
    let* resp, rbody =
      Cohttp_lwt_unix.Client.post ~headers
        ~body:(Cohttp_lwt.Body.of_string body)
        uri
    in
    let+ s = Cohttp_lwt.Body.to_string rbody in
    (Cohttp.Code.code_of_status (Cohttp.Response.status resp), s)
end

module Clock = struct
  let now = Unix.gettimeofday
end

include
  Gcs_backend.Over (Io_lwt.Core) (Http_client_lwt) (Post) (Io_lwt.Lock)
    (Io_lwt.Bounded)
    (Clock)

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("gcs backend: missing field: " ^ key)
  in
  let opt get key = match get key with Some "" | None -> None | s -> s in
  Backend_lwt.register ~spec "gcs" (fun get ->
      make ?endpoint:(opt get "endpoint")
        ?service_account_key:(opt get "serviceAccountKey")
        ?share_url:(opt get "shareUrl") ~bucket:(req get "bucket") ())
