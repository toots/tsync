(* Shared between the http-proxy backend (client) and frontend (server): HMAC
   request authentication over a shared secret, plus the wire encoding of keys and
   listings. No transport here — cohttp lives in the backend/frontend. *)

module Auth = struct
  let timestamp_header = "x-tsync-timestamp"
  let signature_header = "x-tsync-signature"

  (* Reject requests whose timestamp is more than this far from now (replay
     window). Both clocks are assumed roughly in sync. *)
  let max_skew = 300.
  let sha256_hex s = Digestif.SHA256.(to_hex (digest_string s))

  (* Sign method + request-target + timestamp + a hash of the body, so a captured
     signature can't be replayed against a different request or body. *)
  let canonical ~meth ~path ~timestamp ~body =
    String.concat "\n" [meth; path; timestamp; sha256_hex body]

  let sign ~secret ~meth ~path ~timestamp ~body =
    Digestif.SHA256.(
      to_hex (hmac_string ~key:secret (canonical ~meth ~path ~timestamp ~body)))

  let request_headers ~secret ~meth ~path ~body =
    let timestamp = Printf.sprintf "%.0f" (Unix.time ()) in
    [
      (timestamp_header, timestamp);
      (signature_header, sign ~secret ~meth ~path ~timestamp ~body);
    ]

  let verify ~secret ~meth ~path ~timestamp ~signature ~body =
    (match float_of_string_opt timestamp with
      | Some ts -> Float.abs (Unix.time () -. ts) <= max_skew
      | None -> false)
    &&
    let expected = sign ~secret ~meth ~path ~timestamp ~body in
    String.length expected = String.length signature
    && Eqaf.equal expected signature
end

module Wire = struct
  (* Keys hold '/', '-' and hex; base64url makes them a single safe path segment. *)
  let encode_key key =
    Base64.encode_string ~alphabet:Base64.uri_safe_alphabet ~pad:false key

  let decode_key s =
    Base64.decode ~alphabet:Base64.uri_safe_alphabet ~pad:false s

  let file_entry_to_json (e : Backend.file_entry) =
    `Assoc
      [
        ("key", `String e.Backend.key);
        ("size", `Int e.Backend.size);
        ("lastModified", `Float e.Backend.last_modified);
      ]

  let file_entry_of_json json =
    let open Yojson.Safe.Util in
    {
      Backend.key = json |> member "key" |> to_string;
      size = json |> member "size" |> to_int;
      last_modified = json |> member "lastModified" |> to_number;
    }

  let entries_to_json entries =
    Yojson.Safe.to_string (`List (List.map file_entry_to_json entries))

  let entries_of_json s =
    match Yojson.Safe.from_string s with
      | `List l -> List.map file_entry_of_json l
      | _ -> failwith "expected a JSON array of entries"

  (* list_directory returns (files, subdirs-with-optional-mtime). *)
  let list_dir_to_json (files, dirs) =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("files", `List (List.map file_entry_to_json files));
           ( "dirs",
             `List
               (List.map
                  (fun (name, mtime) ->
                    `Assoc
                      [
                        ("name", `String name);
                        ( "mtime",
                          match mtime with Some t -> `Float t | None -> `Null );
                      ])
                  dirs) );
         ])

  let list_dir_of_json s =
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string s in
    let files =
      json |> member "files" |> to_list |> List.map file_entry_of_json
    in
    let dirs =
      json |> member "dirs" |> to_list
      |> List.map (fun d ->
          let name = d |> member "name" |> to_string in
          let mtime =
            match d |> member "mtime" with
              | `Null -> None
              | t -> Some (to_number t)
          in
          (name, mtime))
    in
    (files, dirs)
end
