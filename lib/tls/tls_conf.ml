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

(* Apply a selection by name, raising [Failure] on an unknown or unavailable
   choice. [None] selects the preferred available backend (OpenSSL when it is
   compiled in, else Native). *)
let apply = function
  | None -> (
      match available () with
        | name :: _ -> (
            match of_string name with Some b -> set b | None -> ())
        | [] -> ())
  | Some name -> (
      match of_string name with
        | Some backend -> set backend
        | None ->
            failwith
              (Printf.sprintf "unknown TLS backend %S (choose one of: %s)" name
                 (String.concat ", " (available ()))))
