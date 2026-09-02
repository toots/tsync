(* What the shell is offered, and whether the command accepts it.

   The offer alone proves nothing: a completer that names a spelling the parser
   reads differently is worse than one that says nothing, because it puts the
   wrong path under the user's cursor. So every candidate is fed back to a real
   command and its answer recorded beside it. *)

let root = Scratch.dir "completion"
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

let with_home = Android_home.env ~home

let config =
  Printf.sprintf
    {|{"name":"test","domains":[
        {"name":"Files","versioning":false,"symlinks":"keep","readOnly":false,
         "backends":[{"name":"local","type":"local","path":%s,"role":"main"}],
         "frontends":[{"type":"fuse","mountPoint":%s}]},
        {"name":"Photos","versioning":false,"symlinks":"keep","readOnly":false,
         "backends":[{"name":"local","type":"local","path":%s,"role":"main"}],
         "frontends":[{"type":"fuse","mountPoint":%s}]}]}|}
    (Yojson.Basic.to_string (`String (Filename.concat root "store-files")))
    (Yojson.Basic.to_string (`String (Filename.concat root "mnt-files")))
    (Yojson.Basic.to_string (`String (Filename.concat root "store-photos")))
    (Yojson.Basic.to_string (`String (Filename.concat root "mnt-photos")))

let env =
  Printf.sprintf "%s TSYNC_CONFIG_JSON=%s" with_home (Filename.quote config)

let read_file p =
  let ic = open_in_bin p in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Doc strings arrive styled, which is deterministic but unreadable in a diff. *)
let strip_ansi s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i >= String.length s then Buffer.contents b
    else if s.[i] = '\027' then (
      match String.index_from_opt s i 'm' with
        | Some j -> go (j + 1)
        | None -> Buffer.contents b)
    else begin
      Buffer.add_char b s.[i];
      go (i + 1)
    end
  in
  go 0

let contains needle haystack =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  n > 0 && go 0

let run args =
  let out = Filename.concat root "out.txt" in
  let quoted = List.map Filename.quote (Option.get binary :: args) in
  let status =
    Sys.command
      (Printf.sprintf "%s %s > %s 2>/dev/null" env (String.concat " " quoted)
         (Filename.quote out))
  in
  (status, strip_ansi (read_file out))

(* The protocol frames each candidate between [item] and [item-end]; what a
   reader wants from a snapshot is the candidates. *)
let candidates output =
  let rec go acc = function
    | "item" :: value :: rest -> go (value :: acc) rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] (String.split_on_char '\n' output)

let complete args token =
  snd (run ((["--__complete"] @ args) @ ["--__complete=" ^ token]))

let offers name args token =
  Check.case name;
  let out = complete args token in
  let items = candidates out in
  List.iter (fun c -> Check.step "offers %s" c) items;
  if items = [] then Check.step "offers nothing";
  items

(* An offer the parser then reads as something else is the failure this design
   exists to make impossible. A listing cannot show it -- a missing folder in a
   real domain lists nothing and succeeds -- so the copy is asked instead, which
   says [gone] for a source it could not find. *)
let accepted candidate =
  let status, out =
    run ["rsync"; "--dry-run"; candidate; Filename.concat root "probe"]
  in
  (* A prefix that is not there enumerates nothing and reports success, so what
     is asserted is that the run saw an entry at all. *)
  let found =
    (not (contains "gone" out)) && not (contains "0 copied, 0 skipped, 0 " out)
  in
  Check.step "%s -> exit %d, %s" candidate status
    (if found then "found" else "NOT FOUND");
  Check.check
    (Printf.sprintf "%s names something that is there" candidate)
    (status = 0 && found)

let () =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote home)));
  List.iter
    (fun d ->
      ignore
        (Sys.command
           (Printf.sprintf "mkdir -p %s"
              (Filename.quote (Filename.concat root d)))))
    ["store-files"; "store-photos"; "seed/session"];
  ignore
    (Sys.command
       (Printf.sprintf "printf 'x\\n' > %s; printf 'y\\n' > %s"
          (Filename.quote (Filename.concat root "seed/session/notes.txt"))
          (Filename.quote (Filename.concat root "seed/take.wav"))));
  ignore (run ["import"; "--domain"; "Files"; Filename.concat root "seed"]);

  let names = offers "the domains a config knows" ["ls"; "--domain"] "" in
  Check.check "both domains are offered" (List.length names = 2);

  ignore (offers "narrowed by what is typed" ["ls"; "--domain"] "Ph");

  let top = offers "inside a domain named outright" ["rsync"] "Files:/" in
  Check.check "the imported folder is offered" (top <> []);

  let deep = offers "further in" ["rsync"] "Files:/session/" in
  ignore (offers "narrowed by a partial leaf" ["rsync"] "Files:/session/no");
  ignore (offers "a folder that is not there" ["rsync"] "Files:/nope/");
  ignore (offers "a domain prefix" ["rsync"] "Fi");

  Check.case "every offer is a spelling the command accepts";
  List.iter accepted (top @ deep);

  (* Printed and then reported as success is the shape of the bug, so the code
     is asserted and not merely rendered. *)
  Check.case
    "a path under no domain is refused in the exit code, not just on stderr";
  List.iter
    (fun args ->
      let status, _ = run args in
      Check.step "%s -> exit %d" (String.concat " " args) status;
      Check.check
        (Printf.sprintf "%s does not report success" (String.concat " " args))
        (status <> 0))
    [
      ["ls"; "--domain"; "Files"; "/nonsense"];
      ["cache"; "--domain"; "Files"; "--evict"; "/nonsense"];
      ["versions"; "--domain"; "Files"; "/nonsense"];
    ];

  Check.report ()
