let bin =
  match Sys.getenv_opt "TSYNC_BIN" with
    | Some p -> p
    | None -> "_build/default/bin/tsync.exe"

let config =
  match Sys.getenv_opt "TSYNC_LIVE_CONFIG" with
    | Some p when Sys.file_exists p -> p
    | Some p ->
        Printf.eprintf "TSYNC_LIVE_CONFIG=%s does not exist\n" p;
        exit 2
    | None ->
        prerr_endline
          "a live suite needs TSYNC_LIVE_CONFIG=<config.json> naming one \
           writable domain, whose fuse mountPoint is how a path names the \
           domain side of an operation.";
        exit 2

let read_file p =
  let ic = open_in_bin p in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let json = read_file config

let field ?(from = 0) name =
  let re = Str.regexp ("\"" ^ name ^ "\"[ \t\n]*:[ \t\n]*\"\\([^\"]*\\)\"") in
  try
    ignore (Str.search_forward re json from);
    Str.matched_group 1 json
  with Not_found ->
    Printf.eprintf "config has no %S\n" name;
    exit 2

(* The client's own name sits above the domains and would answer first, so the
   domain is read from inside the array. *)
let domains_at =
  try Str.search_forward (Str.regexp_string "\"domains\"") json 0
  with Not_found ->
    prerr_endline "config has no \"domains\"";
    exit 2

let domain = field ~from:domains_at "name"
let mount = field "mountPoint"
let scratch = Filename.concat (Filename.get_temp_dir_name ()) "tsync-live"
let home = Filename.concat scratch "home"
let q = Filename.quote

(* Each run works under a prefix of its own, so a suite left behind by a failure
   never decides what the next one sees. *)
let stamp = Printf.sprintf "live%d" (int_of_float (Unix.gettimeofday ()))
let rel_in_domain rel = if rel = "" then stamp else stamp ^ "/" ^ rel
let in_domain rel = Filename.concat mount (rel_in_domain rel)
let local rel = Filename.concat scratch rel

let shell cmd =
  let full =
    Printf.sprintf "HOME=%s TSYNC_CONFIG_JSON=%s %s 2>&1" (q home) (q json) cmd
  in
  let ic = Unix.open_process_in full in
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  ignore (Unix.close_process_in ic);
  Buffer.contents buf

let tsync args = shell (Printf.sprintf "%s %s" bin args)

let contains needle haystack =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  n = 0 || go 0

let count kind output =
  let re = Str.regexp ("\\([0-9]+\\) " ^ kind) in
  try
    ignore (Str.search_forward re output 0);
    int_of_string (Str.matched_group 1 output)
  with Not_found -> -1

type expect =
  | Copied of int
  | Skipped of int
  | Dirs of int
  | Failed of int
  | Says of string
  | Silent_on of string
  | Moved_nothing
  | Holds of string * (unit -> bool)

type run = Tsync of string | Shell of string
type case = { name : string; command : run; expect : expect list }
type group = { title : string; cases : case list }

let describe = function
  | Copied n -> Printf.sprintf "copies %d" n
  | Skipped n -> Printf.sprintf "skips %d" n
  | Dirs n ->
      Printf.sprintf "makes %d director%s" n (if n = 1 then "y" else "ies")
  | Failed n -> Printf.sprintf "fails %d" n
  | Says s -> Printf.sprintf "says %S" s
  | Silent_on s -> Printf.sprintf "does not say %S" s
  | Moved_nothing -> "moves nothing"
  | Holds (what, _) -> what

let holds output = function
  | Copied n -> count "copied" output = n
  | Skipped n -> count "skipped" output = n
  | Dirs n -> count "director" output = n
  | Failed n -> count "failed" output = n
  | Says s -> contains s output
  | Silent_on s -> not (contains s output)
  | Moved_nothing -> contains "(0 B moved)" output
  | Holds (_, f) -> ( try f () with _ -> false)

(* The output of a case that fails, since a live failure is usually explained by
   what the command said and nothing else has a copy of it. *)
let report_failure name output =
  Printf.printf "    --- %s said:\n" name;
  List.iter
    (fun l -> if l <> "" then Printf.printf "    | %s\n" l)
    (String.split_on_char '\n' output)

let run_case { name; command; expect } =
  let output =
    match command with Tsync args -> tsync args | Shell cmd -> shell cmd
  in
  let failed_before = Check.failures () in
  List.iter
    (fun e ->
      Check.check (Printf.sprintf "%s: %s" name (describe e)) (holds output e))
    expect;
  if Check.failures () > failed_before then report_failure name output

(* Every declared expectation is counted, so a suite that stops early reports a
   short run rather than a pass. *)
let run_groups groups =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (q scratch)));
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (q home)));
  let expected =
    List.fold_left
      (fun n g ->
        List.fold_left (fun n c -> n + List.length c.expect) n g.cases)
      0 groups
  in
  List.iter
    (fun g ->
      Check.case g.title;
      List.iter run_case g.cases)
    groups;
  (* Left behind on failure: a run that ended early is one whose objects someone
     wants to look at. *)
  if Check.failures () = 0 then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (q scratch)))
  else Printf.printf "\nscratch kept at %s\n" scratch;
  Check.report ~expected ()
