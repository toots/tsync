(* android §4.1 item 2: an empty trust store path is a path, so boot refuses
   it; a host giving no path boots. *)

open Tsync_core

external init_and_boot : string option -> string -> string -> string
  = "tsync_test_init_and_boot"

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-trust-store-%d" (Unix.getpid ()))

let () =
  Fs.rm_rf root;
  Fs.mkdir_p (Filename.concat root "home/.config/tsync");
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_CONFIG_HOME" "";
  Unix.putenv "TSYNC_CONFIG_FILE" (Filename.concat root "config.json");
  Out_channel.with_open_bin (Filename.concat root "config.json") (fun oc ->
      Printf.fprintf oc
        {|{"name":"phone","domains":[{"name":"docs","symlinks":"skip","versioning":true,"extensions":[],"frontends":["android"],"backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
        root);
  Unix.chmod (Filename.concat root "config.json") 0o600;
  Tsync_android_bridge.Android_bridge.started ();
  let boot label trust_store =
    let sentence = init_and_boot trust_store root "docs" in
    Printf.printf "%-14s %s\n%!" label
      (if sentence = "" then "boots" else sentence)
  in
  boot "an empty path" (Some "");
  boot "no path" None;
  Fs.rm_rf root
