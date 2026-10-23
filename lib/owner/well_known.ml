open Tsync_core

let max_body = 256 * 1024

let fetch_https host path =
  try
    let endpoint = Tsync_http.Client.endpoint ("https://" ^ host) in
    let r = Tsync_http.Client.request ~stall:5. endpoint ~meth:"GET" path in
    if r.status = 200 && Bigstring.length r.body <= max_body then
      Some (Bigstring.to_string r.body)
    else None
  with Fail.E _ -> None

let fetch = Atomic.make fetch_https
