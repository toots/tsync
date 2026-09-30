open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(http_url ~bare_host:false)
        "url" "Server URL" String;
      f ~secret:true ~required:true ~check:secret_length "secret"
        "Shared secret" String;
      f ~check:absolute_path "ca_certificate" "CA bundle" Path;
    ]
