open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(fun b ->
          if b = "" || String.contains b '/' then Some "invalid bucket name"
          else None)
        "bucket" "Bucket" String;
      f ~secret:true "serviceAccountKey" "Service account key (JSON)" String;
      f ~check:(http_url ~bare_host:false) "endpoint" "Endpoint" String;
      f "shareUrl" "Share URL" String;
    ]
