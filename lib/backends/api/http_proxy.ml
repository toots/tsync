module Auth = struct
  let timestamp_header = "x-tsync-timestamp"
  let signature_header = "x-tsync-signature"

  (* Replay window: both clocks are assumed roughly in sync. *)
  let max_skew = 300.

  (* Over the bytes where they lie: a chunk body is the largest thing signed
     here, and materialising one as a string to hash it would put the megabytes
     back on the heap that carrying it as a chunk keeps off. *)
  let sha256_hex body = Digestif.SHA256.(to_hex (digest_bigstring body))

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

module Watch = struct
  let max_seconds = 30.
  let wait_param = "wait"
  let last_seen_param = "last_seen"
  let answered_header = "x-tsync-watched"
end

module Wire = struct
  let encode_key key =
    Base64.encode_string ~alphabet:Base64.uri_safe_alphabet ~pad:false key

  let decode_key s =
    Base64.decode ~alphabet:Base64.uri_safe_alphabet ~pad:false s

  (* Passed through rather than dropped: a client behind a proxy caches bodies
     against what the serving store calls their version, and this end is the
     only one that has it. Omitted for a store that names no version, which is
     not the same as an empty one. *)
  let file_entry_to_json (e : Backend.file_entry) =
    `Assoc
      ([
         ("key", `String (Stored_key.to_string e.Backend.key));
         ("size", `Int e.Backend.size);
         ("lastModified", `Float e.Backend.last_modified);
       ]
      @
        match e.Backend.etag with
        | Some etag -> [("etag", `String etag)]
        | None -> [])

  let file_entry_of_json json =
    let open Yojson.Safe.Util in
    {
      Backend.key = Stored_key.listed (json |> member "key" |> to_string);
      size = json |> member "size" |> to_int;
      last_modified = json |> member "lastModified" |> to_number;
      etag =
        (match json |> member "etag" with `String e -> Some e | _ -> None);
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

  let be32 n =
    let buf = Buffer.create 4 in
    add_be32 buf n;
    Buffer.contents buf

  (* One body's frame as pieces, so an answer can go out piece by piece and
     is never held whole beside the bodies it was made from. *)
  let body_parts (_, body) =
    match body with
      | None -> [be32 absent]
      | Some b -> [be32 (Bigstring.length b); Bigstring.to_string b]

  let bodies_to_string answered =
    String.concat "" (List.concat_map body_parts answered)

  let add_field buf s =
    add_be32 buf (String.length s);
    Buffer.add_string buf s

  (* Per folder: its prefix, its listing as JSON, then a count and a key with a
     body or [absent] for each child object answered. In pieces, as
     {!body_parts} is, and for the same reason. *)
  let folder_parts (prefix, (c : Backend.children)) =
    let buf = Buffer.create 256 in
    add_field buf prefix;
    add_field buf (entries_to_json c.Backend.listed);
    add_be32 buf (List.length c.Backend.bodies);
    Buffer.contents buf
    :: List.concat_map
         (fun ((key, _) as answered) ->
           let k = Buffer.create 64 in
           add_field k (Stored_key.to_string key);
           Buffer.contents k :: body_parts answered)
         c.Backend.bodies

  let children_to_string answered =
    String.concat "" (List.concat_map folder_parts answered)

  let children_of_string s =
    let len = String.length s in
    let short () = failwith "children-multi: truncated answer" in
    let count pos =
      if pos + 4 > len then short ();
      (be32_at s pos, pos + 4)
    in
    (* Compared against what is left rather than added to [pos]: a hostile
       length near [max_int] overflows the sum on a 32-bit build. *)
    let field pos =
      let n, pos = count pos in
      if n < 0 || n > len - pos then short ();
      (String.sub s pos n, pos + n)
    in
    let rec bodies n pos acc =
      if n = 0 then (List.rev acc, pos)
      else (
        let key, pos = field pos in
        let size, pos = count pos in
        let key = Stored_key.listed key in
        if size = absent then bodies (n - 1) pos ((key, None) :: acc)
        else begin
          if size < 0 || size > len - pos then short ();
          let body = Bigstring.of_string (String.sub s pos size) in
          bodies (n - 1) (pos + size) ((key, Some body) :: acc)
        end)
    in
    let rec folders pos acc =
      if pos = len then List.rev acc
      else (
        let prefix, pos = field pos in
        let listed, pos = field pos in
        let n, pos = count pos in
        let bodies, pos = bodies n pos [] in
        folders pos
          ((prefix, { Backend.listed = entries_of_json listed; bodies }) :: acc))
    in
    folders 0 []

  let bodies_of_string ~keys s =
    let len = String.length s in
    let short () =
      failwith "get-multi: answer shorter than the keys asked for"
    in
    let rec go pos = function
      | [] ->
          if pos <> len then
            failwith "get-multi: answer longer than the keys asked for";
          []
      | key :: rest ->
          if pos + 4 > len then short ();
          let n = be32_at s pos in
          (* Compared against what is left rather than added to [pos]: a
             hostile length near [max_int] overflows the sum on a 32-bit build,
             and the guard would then pass a negative one to [String.sub], which
             raises [Invalid_argument] where this promises [Failure]. *)
          if n = absent then (key, None) :: go (pos + 4) rest
          else if n < 0 || n > len - pos - 4 then short ()
          else
            (key, Some (Bigstring.of_string (String.sub s (pos + 4) n)))
            :: go (pos + 4 + n) rest
    in
    go 0 keys
end
