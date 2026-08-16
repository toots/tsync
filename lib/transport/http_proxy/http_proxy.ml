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

  (* A page is the array [entries_to_json] already writes, and the newline
     separates two of them, which is sound because Yojson escapes a newline
     inside a key rather than emitting one. *)
  let page_line entries = entries_to_json entries ^ "\n"

  (* A chunked response that stops early is indistinguishable from one that
     finished, and a source listing silently cut short means objects the resync
     never copies and never mentions. The terminator is what a reader checks for
     instead of trusting end-of-body. *)
  let done_line = "{\"done\":true}\n"

  let error_line msg =
    Yojson.Safe.to_string (`Assoc [("error", `String msg)]) ^ "\n"

  (* The network splits a body wherever it likes, so reassembly belongs with the
     framing rather than in whoever happens to be reading. *)
  type reader = { mutable rest : string }

  let reader () = { rest = "" }
  let rest r = r.rest

  let feed r chunk =
    let s = r.rest ^ chunk in
    let len = String.length s in
    let rec go start acc =
      match String.index_from_opt s start '\n' with
        | None ->
            r.rest <- String.sub s start (len - start);
            List.rev acc
        | Some i ->
            let line = String.sub s start (i - start) in
            go (i + 1) (if line = "" then acc else line :: acc)
    in
    go 0 []

  let parse_line line =
    match Yojson.Safe.from_string line with
      | `List _ -> `Page (entries_of_json line)
      | `Assoc _ as j -> (
          let open Yojson.Safe.Util in
          match j |> member "error" with
            | `String msg -> `Error msg
            | _ -> (
                match j |> member "done" with
                  | `Bool true -> `Done
                  | _ -> failwith "unrecognised listing line"))
      | _ -> failwith "unrecognised listing line"
end
