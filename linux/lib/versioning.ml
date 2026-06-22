let trash_key ~s3_key ~domain_prefix ~trash_prefix =
  let relative =
    if
      String.length s3_key > String.length domain_prefix
      && String.sub s3_key 0 (String.length domain_prefix) = domain_prefix
    then
      String.sub s3_key
        (String.length domain_prefix)
        (String.length s3_key - String.length domain_prefix)
    else s3_key
  in
  let ts = Int64.of_float (Unix.gettimeofday ()) in
  Printf.sprintf "%s%s/%Ld" trash_prefix relative ts
