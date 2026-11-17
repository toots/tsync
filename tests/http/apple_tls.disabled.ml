(* A macOS build without Network.framework would test OpenSSL twice. *)
let check () =
  if Tsync_core.Fs.is_macos then
    failwith "tls_trust_test: built without Network.framework on macOS"
