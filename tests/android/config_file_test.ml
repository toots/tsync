(* 07 §2.7: $TSYNC_CONFIG_FILE names the config file an embedding host
   shares with another process, in place of the one under its home. *)

open Tsync_core
open Tsync_android

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-config-file-%d" (Unix.getpid ()))

let shared = Filename.concat root "group/config.json"

let config =
  Printf.sprintf
    {|{"name":"phone","domains":[{"name":"docs","symlinks":"skip","versioning":true,"extensions":[],"frontends":["android"],"backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
    root

let check label =
  let sentence = Android_host.check_config "docs" in
  Printf.printf "%-26s %s\n%!" label
    (if sentence = "" then "loads"
     else Text.replace_all ~sub:(root ^ "/") ~by:"" sentence)

let () =
  Fs.rm_rf root;
  Fs.mkdir_p (Filename.concat root "home");
  Fs.mkdir_p (Filename.dirname shared);
  Unix.putenv "HOME" (Filename.concat root "home");
  (* A runner may set it, and it outranks the home. *)
  Unix.putenv "XDG_CONFIG_HOME" "";
  Out_channel.with_open_bin shared (fun oc -> output_string oc config);
  Unix.chmod shared 0o600;
  check "under home only";
  Unix.putenv "TSYNC_CONFIG_FILE" shared;
  check "named by the host";
  Unix.putenv "TSYNC_CONFIG_FILE" "group/config.json";
  check "a relative name";
  Fs.rm_rf root
