(* Runtime selection of conduit's TLS backend for the S3 client.

   conduit-lwt-unix picks a backend once at startup (its [tls_library] ref).
   [Native] (ocaml-tls, via tls-lwt) is a mandatory dependency and the default;
   [OpenSSL] (via lwt_ssl) is optional and only available when lwt_ssl happens
   to be installed in the switch. The OpenSSL backend has a per-connection
   error-queue bug that breaks some S3-compatible endpoints (Backblaze B2), so
   Native is preferred; OpenSSL stays selectable for legacy compatibility. *)

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

(* Backends compiled into this build, preferred first. *)
let available () =
  List.filter_map
    (fun b -> if is_available b then Some (to_string b) else None)
    [Native; Openssl]

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
   choice. [None] leaves conduit's compiled-in default in place. *)
let apply = function
  | None -> ()
  | Some name -> (
      match of_string name with
        | Some backend -> set backend
        | None ->
            failwith
              (Printf.sprintf "unknown TLS backend %S (choose one of: %s)" name
                 (String.concat ", " (available ()))))
