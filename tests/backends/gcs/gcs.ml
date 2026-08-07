(* Pure-helper unit tests for the GCS backend, no network: the parsing and
   encoding that has to be exactly right. The full HTTP roundtrip is exercised
   manually against fake-gcs-server. *)

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let () =
  (* An object name is one path segment, so every reserved character — [/]
     included — must be percent-encoded. *)
  check "enc_key encodes slashes and reserved chars"
    (Gcs_backend.enc_key "tsync/d/.chunks/aabb-ccdd"
    = "tsync%2Fd%2F.chunks%2Faabb-ccdd");
  check "enc_key leaves unreserved intact"
    (Gcs_backend.enc_key "a-b_c.d~e" = "a-b_c.d~e");

  (* GCS [updated] is RFC-3339 UTC; parse to epoch seconds. *)
  let t = Gcs_backend.parse_rfc3339 "1970-01-01T00:00:00.000Z" in
  check "epoch zero" (t = 0.);
  let t = Gcs_backend.parse_rfc3339 "2001-09-09T01:46:40Z" in
  check "known epoch 1e9" (t = 1_000_000_000.);
  check "garbage timestamp -> 0" (Gcs_backend.parse_rfc3339 "not-a-date" = 0.);

  (* List response: string sizes, nextPageToken. *)
  let body =
    {|{"items":[{"name":"a/x","size":"11","updated":"2001-09-09T01:46:40Z"},
               {"name":"a/y","size":"3","updated":"2001-09-09T01:46:40Z"}],
      "nextPageToken":"tok42"}|}
  in
  let items, next = Gcs_backend.parse_list body in
  check "parse_list count" (List.length items = 2);
  check "parse_list first key" ((List.hd items).Backend.key = "a/x");
  check "parse_list string size" ((List.hd items).Backend.size = 11);
  check "parse_list next token" (next = Some "tok42");
  let _, next = Gcs_backend.parse_list {|{"items":[]}|} in
  check "parse_list no token" (next = None);

  print_endline "gcs: all helper checks passed"
