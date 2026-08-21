(* What a failed request puts in the log.

   The body is whatever the far side felt like sending: a store's own error
   object, a proxy's HTML page, a sentence, nothing at all. All of it has to
   come back as one bounded line, because this lands in a warning that repeats
   once per retry.

   A snapshot, so a reworded rule shows up as the excerpt it produces rather
   than as an assertion someone has to decode. *)

let show name body =
  Printf.printf "=== %s\n%s\n\n" name (Http_client.excerpt body)

let () =
  (* The case the first-line rule got wrong: a store's error opens on a lone
     brace, so cutting at the newline excerpted the punctuation. *)
  show "pretty-printed JSON, as GCS answers a 429"
    {|{
  "error": {
    "code": 429,
    "message": "The rate of change requests to the object exceeds the limit.",
    "status": "RESOURCE_EXHAUSTED"
  }
}|};

  show "an nginx error page"
    "<html>\r\n\
     <head><title>502 Bad Gateway</title></head>\r\n\
     <body>\r\n\
     <center><h1>502 Bad Gateway</h1></center>\r\n\
     <hr><center>nginx/1.24.0</center>\r\n\
     </body>\r\n\
     </html>\r\n";

  show "one line, short enough to stand on its own"
    "InvalidAccessKeyId: the key is not on file";

  show "a body longer than the limit, on one line" (String.make 400 'x');

  show "an XML error, as S3 answers"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
     <Error><Code>SlowDown</Code><Message>Please reduce your request \
     rate.</Message></Error>";

  show "empty" "";
  show "whitespace only" "  \n\t \n  "
