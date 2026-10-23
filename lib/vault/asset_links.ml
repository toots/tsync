let labels s = String.split_on_char '.' (String.lowercase_ascii s)

let candidate ~package host =
  let reversed = List.rev (labels host) and pkg = labels package in
  let rec prefix = function
    | [], _ -> true
    | _, [] -> false
    | a :: r, b :: s -> a = b && prefix (r, s)
  in
  List.length reversed >= 2 && prefix (reversed, pkg)

let fingerprint s =
  String.lowercase_ascii
    (String.concat "" (String.split_on_char ':' (String.trim s)))

let relation = "delegate_permission/common.get_login_creds"

let grants ~package ~certs body =
  let certs = List.map fingerprint certs in
  let member k = function `Assoc l -> List.assoc_opt k l | _ -> None in
  let strings = function
    | Some (`List l) ->
        List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  let statement s =
    List.mem relation (strings (member "relation" s))
    &&
      match member "target" s with
      | Some target ->
          member "namespace" target = Some (`String "android_app")
          && member "package_name" target = Some (`String package)
          && List.exists
               (fun fp -> List.mem (fingerprint fp) certs)
               (strings (member "sha256_cert_fingerprints" target))
      | None -> false
  in
  match Yojson.Safe.from_string body with
    | `List statements -> List.exists statement statements
    | _ -> false
    | exception Yojson.Json_error _ -> false
