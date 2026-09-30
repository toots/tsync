open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(fun b ->
          if b = "" || String.contains b '/' then Some "invalid bucket name"
          else None)
        "bucket" "Bucket" String;
      f ~default:"us-east-1" "region" "Region" String;
      f ~check:(http_url ~bare_host:true) "endpoint" "Endpoint" String;
      f ~required:true "accessKeyId" "Access key id" String;
      f ~secret:true ~required:true "secretAccessKey" "Secret access key" String;
      f ~default:"false" "unsignedPayload" "Unsigned payload" Bool;
      f "shareUrl" "Share URL" String;
    ]
