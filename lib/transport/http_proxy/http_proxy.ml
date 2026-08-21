module Auth = struct
  let timestamp_header = "x-tsync-timestamp"
  let signature_header = "x-tsync-signature"

  (* Replay window: both clocks are assumed roughly in sync. *)
  let max_skew = 300.

  (* Over the bytes where they lie: a chunk body is the largest thing signed
     here, and materialising one as a string to hash it would put the megabytes
     back on the heap that carrying it as a chunk keeps off. *)
  let sha256_hex body =
    Digestif.SHA256.(to_hex (digest_bigstring (Chunk.buffer body)))

  (* Sign method + request-target + timestamp + a hash of the body, so a captured
     signature can't be replayed against a different request or body. *)
  let canonical ~meth ~path ~timestamp ~body =
    String.concat "\n" [meth; path; timestamp; sha256_hex body]

  let sign ~secret ~meth ~path ~timestamp ~body =
    Digestif.SHA256.(
      to_hex (hmac_string ~key:secret (canonical ~meth ~path ~timestamp ~body)))

  let request_headers ?timestamp ~secret ~meth ~path ~body () =
    let timestamp =
      match timestamp with
        | Some t -> t
        | None -> Printf.sprintf "%.0f" (Unix.time ())
    in
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

  (* Distinct from an empty body, which is a real answer for a key holding no
     bytes. *)
  let absent = 0xFFFFFFFF

  let add_be32 buf n =
    let byte shift = Char.chr ((n lsr shift) land 0xff) in
    Buffer.add_char buf (byte 24);
    Buffer.add_char buf (byte 16);
    Buffer.add_char buf (byte 8);
    Buffer.add_char buf (byte 0)

  let be32_at s pos =
    (Char.code s.[pos] lsl 24)
    lor (Char.code s.[pos + 1] lsl 16)
    lor (Char.code s.[pos + 2] lsl 8)
    lor Char.code s.[pos + 3]

  let bodies_to_string answered =
    let buf = Buffer.create 4096 in
    List.iter
      (fun (_, body) ->
        match body with
          | None -> add_be32 buf absent
          | Some b ->
              add_be32 buf (Chunk.length b);
              Buffer.add_string buf (Chunk.to_string b))
      answered;
    Buffer.contents buf

  let bodies_of_string ~keys s =
    let len = String.length s in
    let short () = failwith "get-multi: answer shorter than the keys asked for" in
    let rec go pos = function
      | [] ->
          if pos <> len then
            failwith "get-multi: answer longer than the keys asked for";
          []
      | key :: rest ->
          if pos + 4 > len then short ();
          let n = be32_at s pos in
          if n = absent then (key, None) :: go (pos + 4) rest
          else if pos + 4 + n > len then short ()
          else
            (key, Some (Chunk.of_string (String.sub s (pos + 4) n)))
            :: go (pos + 4 + n) rest
    in
    go 0 keys
end
