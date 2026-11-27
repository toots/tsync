open Tsync_core

let max_body = 256 * 1024

(* passwords §7.3: a page names the host, so the read is bounded in size and
   time, both spent under the vault's locks. *)
let fetch_https host path =
  try
    Rt.with_timeout 10. @@ fun () ->
    let endpoint = Tsync_http.Client.endpoint ("https://" ^ host) in
    (* Meta redirects a request without a User-Agent to its unsupported-browser page. *)
    let headers () = [("user-agent", "tsync")] in
    let r =
      Tsync_http.Client.request ~stall:5. ~max_body ~headers endpoint
        ~meth:"GET" path
    in
    if r.status = 200 then Some (Bigstring.to_string r.body) else None
  with Fail.E _ | Rt.Timeout -> None

let fetch = Atomic.make fetch_https
