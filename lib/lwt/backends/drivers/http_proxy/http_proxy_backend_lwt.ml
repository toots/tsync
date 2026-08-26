(* The peer-proxy store on Lwt, and where it registers itself. *)
include Http_proxy_backend.Over (Io_lwt.Core) (Http_client_lwt)

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("http-proxy backend: missing field: " ^ key)
  in
  Backend_lwt.register ~spec "http-proxy" (fun get ->
      make ~url:(req get "url") ~secret:(req get "secret"))
