open Tsync_core

let ttl = 86400.
let max_body = 256 * 1024

let fetch_https host =
  try
    let endpoint = Tsync_http.Client.endpoint ("https://" ^ host) in
    let r =
      Tsync_http.Client.request ~stall:5. endpoint ~meth:"GET"
        "/.well-known/assetlinks.json"
    in
    if r.status = 200 && Bigstring.length r.body <= max_body then
      Some (Bigstring.to_string r.body)
    else None
  with Fail.E _ -> None

let fetch = Atomic.make fetch_https

(* (host, package, certs) to whether it grants, and until when. *)
let verdicts : (string * string * string, bool * float) Hashtbl.t =
  Hashtbl.create 16

let pending : (string * string * string, unit) Hashtbl.t = Hashtbl.create 16
let lock = Mutex.create ()

let reset () =
  Mutex.protect lock (fun () ->
      Hashtbl.reset verdicts;
      Hashtbl.reset pending)

let verified ~package ~certs hosts =
  let certs_key = String.concat "," (List.sort compare certs) in
  List.filter
    (fun host ->
      Tsync_vault.Asset_links.candidate ~package host
      &&
      let key = (host, package, certs_key) in
      let known =
        Mutex.protect lock (fun () ->
            match Hashtbl.find_opt verdicts key with
              | Some (granted, until) when until > Unix.gettimeofday () ->
                  Some granted
              | _ -> None)
      in
      match known with
        | Some granted -> granted
        | None ->
            let start =
              Mutex.protect lock (fun () ->
                  if Hashtbl.mem pending key then false
                  else (
                    Hashtbl.replace pending key ();
                    true))
            in
            if start then
              Rt.spawn ~name:"asset links" (fun () ->
                  let granted =
                    match (Atomic.get fetch) host with
                      | Some body ->
                          Some
                            (Tsync_vault.Asset_links.grants ~package ~certs body)
                      | None -> None
                  in
                  Mutex.protect lock (fun () ->
                      Hashtbl.remove pending key;
                      (* A fetch that failed keeps nothing: the next request asks again. *)
                      Option.iter
                        (fun g ->
                          Hashtbl.replace verdicts key
                            (g, Unix.gettimeofday () +. ttl))
                        granted));
            false)
    hosts
