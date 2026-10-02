open Tsync_core

let port p =
  match int_of_string_opt p with
    | Some p when p >= 1 && p <= 65535 -> None
    | _ -> Some "expected 1 to 65535"

let fields =
  Field_spec.
    [
      f ~check:port "port" "Port" Int;
      f "bind" "Bind addresses" String;
      f "max_concurrent" "Concurrent data operations" Int;
      f ~check:absolute_path "ssl_certificate" "TLS certificate" Path;
      f ~check:absolute_path "ssl_certificate_key" "TLS key" Path;
      f ~secret:true ~check:secret_length "secret" "Shared secret" String;
      f ~default:"false" "shares" "Serve share links" Bool;
      f ~default:"false" "readOnly" "Read-only" Bool;
      f "max_put_body" "Largest PUT body" Size;
      f "max_bulk_body" "Largest bulk body" Size;
      f "max_body_memory" "Body memory" Size;
      f "idle_timeout" "Idle timeout (s)" Float;
      f "header_timeout" "Header timeout (s)" Float;
      f "keepalive_timeout" "Keep-alive timeout (s)" Float;
      f "max_connections" "Connections" Int;
      f "max_share_responses" "Concurrent share responses" Int;
      f "max_zip_members" "ZIP members" Int;
    ]

let () =
  Tsync_config.Frontend.register "http-proxy"
    {
      fields;
      presenting = None;
      commands_only = None;
      group = None;
      commands = [];
    }
