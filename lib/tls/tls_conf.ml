(* Runtime selection of conduit's TLS backend for the S3 client.

   conduit-lwt-unix picks a backend once at startup (its [tls_library] ref).
   [Native] (ocaml-tls, via tls-lwt) is a mandatory dependency; [OpenSSL] (via
   lwt_ssl) is optional and only available when lwt_ssl is installed in the
   switch. OpenSSL is much faster in general and is preferred by default when
   it is available; Native is a robust fallback that avoids OpenSSL's
   per-connection error-queue bug affecting some S3-compatible endpoints
   (Backblaze B2), so it stays selectable for those situations. *)

type t = Native | Openssl

let to_string = function Native -> "native" | Openssl -> "openssl"

let of_string s =
  match String.lowercase_ascii s with
    | "native" | "tls" -> Some Native
    | "openssl" | "ssl" -> Some Openssl
    | _ -> None

let is_available = function
  | Native -> Conduit_lwt_tls.available
  | Openssl -> Conduit_lwt_unix_ssl.available

(* The backend conduit will actually use for the next connection. *)
let current () =
  match !Conduit_lwt_unix.tls_library with
    | Conduit_lwt_unix.Native -> "native"
    | Conduit_lwt_unix.OpenSSL -> "openssl"
    | Conduit_lwt_unix.No_tls -> "none"

(* Backends compiled into this build, preferred first. OpenSSL is faster in
   general, so it leads when available; Native is the fallback. *)
let available () =
  List.filter_map
    (fun b -> if is_available b then Some (to_string b) else None)
    [Openssl; Native]

let set backend =
  if not (is_available backend) then
    failwith
      (Printf.sprintf "TLS backend %S is not available (built: %s)"
         (to_string backend)
         (String.concat ", " (available ())));
  Conduit_lwt_unix.tls_library :=
    match backend with
      | Native -> Conduit_lwt_unix.Native
      | Openssl -> Conduit_lwt_unix.OpenSSL

(* The preferred backend this build actually has. *)
let use_preferred () =
  match available () with
    | name :: _ -> ( match of_string name with Some b -> set b | None -> ())
    | [] -> ()

(* Apply a selection by name. [None] selects the preferred available backend
   (OpenSSL when it is compiled in, else Native).

   An unknown name is a typo in the config and raises. A known name that this
   build lacks does not: which backends are compiled in is a property of the
   build, not of the configuration — the release build ships without OpenSSL —
   and both backends speak TLS, so the choice is a performance preference. A
   daemon that refuses to start over one is worse than a slower one, so warn
   loudly and carry on with what is here. *)
let apply = function
  | None -> use_preferred ()
  | Some name -> (
      match of_string name with
        | None ->
            failwith
              (Printf.sprintf "unknown TLS backend %S (choose one of: %s)" name
                 (String.concat ", " (available ())))
        | Some backend when is_available backend -> set backend
        | Some backend ->
            use_preferred ();
            Log.warn
              "TLS backend %S is not available in this build (have: %s); using \
               %s instead"
              (to_string backend)
              (String.concat ", " (available ()))
              (current ()))
