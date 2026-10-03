(* android §9, Ownership and boot: the bridge called from foreign threads, and
   a command meeting the host that owns the domain. *)

open Tsync_core
open Tsync_android

external open_before_start : unit -> int = "tsync_test_open_before_start"

external stress : string -> threads:int -> reads:int -> size:int -> int
  = "tsync_test_stress"

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-bridge-%d" (Unix.getpid ()))

let size = 300_000
let threads = 8
let reads = 64

let request fields =
  Yojson.Safe.from_string
    (Android_host.request (Yojson.Safe.to_string (`Assoc fields)))

let field j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let spawned tsync args =
  let out = Filename.concat root "out" in
  let fd = Unix.openfile out [O_WRONLY; O_CREAT; O_TRUNC] 0o600 in
  let pid =
    Unix.create_process tsync (Array.of_list (tsync :: args)) Unix.stdin fd fd
  in
  Unix.close fd;
  let _, status = Unix.waitpid [] pid in
  ( (match status with WEXITED n -> n | _ -> -1),
    String.trim (Fs.read_file out) )

let () =
  let tsync = Sys.argv.(1) in
  Fs.rm_rf root;
  List.iter
    (fun (var, dir) ->
      let dir = Filename.concat root dir in
      Fs.mkdir_p ~perm:0o700 dir;
      Unix.putenv var dir)
    [("HOME", "home"); ("XDG_DATA_HOME", "data"); ("XDG_CACHE_HOME", "cache")];
  Unix.putenv "TSYNC_CONFIG_JSON"
    (Printf.sprintf
       {|{"name":"phone","domains":[{"name":"docs","symlinks":"skip","versioning":true,
          "frontends":["android"],
          "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root);
  p "open before the runtime is announced  %d" (open_before_start ());
  Tsync_android_bridge.Android_bridge.started ();
  p "open before boot                      %d" (Android_host.open_ "root");
  p "boot                                  %S" (Android_host.boot "");
  let staging = Filename.concat (Sys.getenv "HOME") "staged" in
  Fs.write_file_for_test staging
    (String.init size (fun i -> Char.chr (((i * 7) + 3) land 0xff)));
  let written =
    request
      [
        ("action", `String "write");
        ("parentRef", `String "root");
        ("name", `String "big.bin");
        ("staging", `String staging);
        ("await", `Bool true);
      ]
  in
  let ref_ =
    match Option.bind (field written "item") (fun i -> field i "ref") with
      | Some (`String r) -> r
      | _ -> failwith (Yojson.Safe.to_string written)
  in
  p "open of an absent reference           %d"
    (Android_host.open_ "i:00000000000000000000000000000000");
  p "%d foreign threads × %d reads           %d failures" threads reads
    (stress ref_ ~threads ~reads ~size);
  let code, said = spawned tsync ["android"; "stat"; "root"] in
  let pid = string_of_int (Unix.getpid ()) in
  let said =
    (* The holder's pid is this process's. *)
    let n = String.length pid in
    let rec scrub i =
      if i + n > String.length said then said
      else if String.sub said i n = pid then
        String.sub said 0 i ^ "<pid>"
        ^ String.sub said (i + n) (String.length said - i - n)
      else scrub (i + 1)
    in
    scrub 0
  in
  p "a command while the host owns it      exit %d: %s" code said;
  Test_support.remove_root root;
  exit 0
