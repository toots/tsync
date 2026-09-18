(* How `tsync export' reads its arguments: the last is where to write, anything
   before it is what, and a domain is named by [--domain], by [DOMAIN:/path], or
   not at all.

   Every case is the real binary against a local store, its folder dumped after,
   so what a spelling means is what it wrote. *)

let root = Scratch.dir "export-cli"
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

let domain name port =
  Printf.sprintf
    {|{"name":%S,"versioning":false,"symlinks":"keep","readOnly":false,
       "backends":[{"name":"local","type":"local","path":%s,"role":"main"}],
       "frontends":[{"type":"http-proxy","port":%d,"secret":"s"}]}|}
    name
    (Yojson.Basic.to_string (`String (Filename.concat root ("store-" ^ name))))
    port

let config =
  Printf.sprintf {|{"name":"test","domains":[%s,%s]}|} (domain "Files" 8797)
    (domain "Other" 8798)

let env =
  Printf.sprintf "%s TSYNC_CONFIG_JSON=%s" (Android_home.env ~home)
    (Filename.quote config)

let read_file p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt
let lines text = List.filter (fun l -> l <> "") (String.split_on_char '\n' text)

let run args =
  let out = Filename.concat root "out.txt"
  and err = Filename.concat root "err.txt" in
  let quoted = List.map Filename.quote (Option.get binary :: args) in
  let status =
    Sys.command
      (Printf.sprintf "cd %s && %s %s > %s 2> %s" (Filename.quote root) env
         (String.concat " " quoted) (Filename.quote out) (Filename.quote err))
  in
  (status, lines (read_file out), lines (read_file err))

let rec walk dir =
  match Sys.readdir dir with
    | exception Sys_error _ -> []
    | names ->
        List.concat_map
          (fun name ->
            let path = Filename.concat dir name in
            if Sys.is_directory path then
              List.map (fun rest -> name ^ "/" ^ rest) (walk path)
            else [name])
          (List.sort compare (Array.to_list names))

let mask_root line =
  let n = String.length root in
  let rec go i acc =
    if i >= String.length line then acc
    else if i + n <= String.length line && String.sub line i n = root then
      go (i + n) (acc ^ "<root>")
    else go (i + 1) (acc ^ String.make 1 line.[i])
  in
  go 0 ""

(* Files finish in the order their chunks land; errors are said as the binary
   says them, a log line's timestamp aside. *)
let case ?(dir = "out") label args =
  let dst = Filename.concat root dir in
  Check.case label;
  let shown = List.map (fun a -> if a = "DIR" then dir else a) args in
  Check.step "$ tsync export %s"
    (String.concat " " (List.map Filename.quote shown));
  let status, out, err =
    run ("export" :: List.map (fun a -> if a = "DIR" then dst else a) args)
  in
  List.iter (fun l -> Check.step "%s" (mask_root l)) (List.sort compare out);
  List.iter
    (fun l -> Check.step "! %s" (mask_root l))
    (List.filter
       (fun l -> String.length l < 5 || String.sub l 0 3 <> "202")
       err);
  Check.step "exit %d" status;
  List.iter (fun f -> Check.step "wrote %s" f) (walk dst);
  sh "rm -rf %s" (Filename.quote dst);
  status

let () =
  List.iter
    (fun d -> sh "mkdir -p %s" (Filename.quote (Filename.concat root d)))
    ["store-Files"; "store-Other"; "seed/sub/deep"; "elsewhere"];
  sh "printf alpha > %s" (Filename.quote (Filename.concat root "seed/a.txt"));
  sh "printf bravo > %s"
    (Filename.quote (Filename.concat root "seed/sub/b.txt"));
  sh "printf charlie > %s"
    (Filename.quote (Filename.concat root "seed/sub/deep/c d.txt"));
  ignore (run ["import"; "--domain"; "Files"; Filename.concat root "seed"]);
  sh "printf other > %s"
    (Filename.quote (Filename.concat root "elsewhere/o.txt"));
  ignore (run ["import"; "--domain"; "Other"; Filename.concat root "elsewhere"]);

  let ok = ref 0 and refused = ref 0 in
  let expect_ok s = if s = 0 then incr ok
  and expect_refused s = if s <> 0 then incr refused in
  expect_ok
    (case "the whole domain, as it was always spelled"
       ["--domain"; "Files"; "DIR"]);
  expect_ok (case "the whole domain, named outright" ["Files:"; "DIR"]);
  expect_ok (case "a folder" ["Files:/sub"; "DIR"]);
  expect_ok (case "a folder, without the slash" ["Files:sub/deep/"; "DIR"]);
  expect_ok
    (case "a file with a space in it" ["Files:/sub/deep/c d.txt"; "DIR"]);
  expect_ok
    (case "several, relative to the domain named"
       ["--domain"; "Files"; "sub/b.txt"; "a.txt"; "DIR"]);
  expect_ok (case "the other domain" ["Other:/"; "DIR"]);
  expect_ok
    (case "a destination relative to where it is run" ~dir:"rel/out"
       ["Files:/a.txt"; "rel/out"]);
  expect_refused
    (case "a path the domain does not have" ["Files:/nope.txt"; "DIR"]);
  expect_refused
    (case "two domains in one run" ["Files:/a.txt"; "Other:/o.txt"; "DIR"]);
  expect_refused
    (case "a domain named twice, differently"
       ["--domain"; "Other"; "Files:/a.txt"; "DIR"]);
  expect_refused (case "no destination" []);
  Check.check "every spelling that names something exports it" (!ok = 8);
  Check.check "and every one that does not is refused" (!refused = 4);
  Check.report ~expected:2 ();
  Scratch.cleanup root
