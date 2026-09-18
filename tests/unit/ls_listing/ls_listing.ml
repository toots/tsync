(* What `tsync ls' prints for one folder.

   The frontend is http-proxy because every platform compiles that one in: a
   command resolves a frontend before it lists anything, and a config naming one
   this binary was built without fails before the listing is reached.

   A listing names what is in the folder asked for, so every row is a leaf:
   a row carrying the whole path reads as a file somewhere else, and the
   directories beside it never did. *)

let root = Scratch.dir "ls-listing"
let home = Filename.concat root "home"

let binary =
  let rec upwards dir n =
    if n = 0 then None
    else (
      let candidate = Filename.concat dir "bin/tsync.exe" in
      if Sys.file_exists candidate then Some candidate
      else upwards (Filename.dirname dir) (n - 1))
  in
  upwards (Sys.getcwd ()) 6

let config =
  Printf.sprintf
    {|{"name":"test","domains":[
        {"name":"Files","versioning":false,"symlinks":"keep","readOnly":false,
         "backends":[{"name":"local","type":"local","path":%s,"role":"main"}],
         "frontends":[{"type":"http-proxy","port":8799,"secret":"s"}]}]}|}
    (Yojson.Basic.to_string (`String (Filename.concat root "store")))

let env =
  Printf.sprintf "%s TSYNC_CONFIG_JSON=%s" (Android_home.env ~home)
    (Filename.quote config)

let read_file p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt

let run args =
  let out = Filename.concat root "out.txt" in
  let quoted = List.map Filename.quote (Option.get binary :: args) in
  let status =
    Sys.command
      (Printf.sprintf "%s %s > %s 2>/dev/null" env (String.concat " " quoted)
         (Filename.quote out))
  in
  (status, read_file out)

(* The size a row carries is the file's, which this test does not choose. *)
let mask line =
  match String.rindex_opt line ' ' with
    | Some _ when String.length line > 6 && String.sub line 0 6 = "online" ->
        let parts = String.split_on_char ' ' line in
        String.concat " "
          (List.mapi
             (fun i p -> if i = List.length parts - 2 then "<n>" else p)
             parts)
    | _ -> line

let () =
  sh "mkdir -p %s" (Filename.quote (Filename.concat root "store"));
  List.iter
    (fun d -> sh "mkdir -p %s" (Filename.quote (Filename.concat root d)))
    ["seed/Festivals/audio"; "seed/Festivals/Horn charts"];
  sh "printf 'a,b\\n' > %s"
    (Filename.quote (Filename.concat root "seed/Festivals/Activity.csv"));
  sh "printf 'x\\n' > %s"
    (Filename.quote (Filename.concat root "seed/Festivals/audio/take.wav"));
  ignore (run ["import"; "--domain"; "Files"; Filename.concat root "seed"]);

  Check.case "a folder holding both";
  let status, out = run ["ls"; "--domain"; "Files"; "Festivals"] in
  List.iter
    (fun l -> if l <> "" then Check.step "%s" (mask l))
    (String.split_on_char '\n' out);
  Check.check "it is listed" (status = 0);
  Check.check "every row names a leaf, the file's included"
    (List.for_all
       (fun l ->
         l = "" || not (String.contains l '/' && l.[String.length l - 1] <> '/'))
       (String.split_on_char '\n' out));
  Check.report ~expected:2 ();
  Scratch.cleanup root
