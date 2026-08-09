(* Runtime selection of conduit's TLS backend, which conduit-lwt-unix picks once
   at startup via its [tls_library] ref.

   [Native] (ocaml-tls) is a mandatory dependency; [OpenSSL] (lwt_ssl) is optional
   and much faster, so it is preferred when compiled in. Native stays selectable
   because it avoids OpenSSL's per-connection error-queue bug, which affects some
   S3-compatible endpoints (Backblaze B2). *)

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

let current () =
  match !Conduit_lwt_unix.tls_library with
    | Conduit_lwt_unix.Native -> "native"
    | Conduit_lwt_unix.OpenSSL -> "openssl"
    | Conduit_lwt_unix.No_tls -> "none"

(* Preferred first: OpenSSL when available, else Native. *)
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

let use_preferred () =
  match available () with
    | name :: _ -> ( match of_string name with Some b -> set b | None -> ())
    | [] -> ()

(* An unknown name is a typo in the config and raises; a known name this build
   lacks only warns, since which backends are linked is a property of the build
   and both speak TLS. *)
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
