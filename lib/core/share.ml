(* Zip entry name for a shared folder. Entries are rooted at the shared folder
   itself, so sharing "A/B/shared" yields "shared/..." rather than the full
   domain-relative path.

   [domain_prefix] is the domain's S3 key prefix, [rel] the shared folder's
   domain-relative path (no trailing slash; "" for a whole-domain share), and
   [key] a decoded object key under it. *)
let zip_entry_name ~domain_prefix ~rel key =
  let parent =
    match String.rindex_opt rel '/' with
      | Some i -> String.sub rel 0 (i + 1)
      | None -> ""
  in
  let strip = String.length domain_prefix + String.length parent in
  if String.length key > strip then
    String.sub key strip (String.length key - strip)
  else key
