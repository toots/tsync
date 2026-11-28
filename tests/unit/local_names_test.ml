(* local-names: the local tree is a function of the exact state, on a disk that
   conflates names (macOS CI: case-insensitive APFS) as on one that does not. *)

open Tsync_core
open Tsync_checkout

let p fmt = Printf.printf fmt
let root = Filename.temp_dir "tsync-local-names" ""
let times = { Fs.mtime = 0; created = 0 }
let seq = ref 0

let fresh () =
  incr seq;
  Mirror.create ~cache_root:root (Domain_name.v (Printf.sprintf "h%d" !seq))

let folder_dir t =
  Filename.concat (Filename.concat (Mirror.root t) "manifests") "d"

let flagged t =
  Sys.file_exists (Filename.concat (folder_dir t) ".tsync-demoted")

(* The target says which name a manifest was written for. *)
let put t n =
  Mirror.write_file ~durable:false t ("d/" ^ n)
    (Manifest.symlink ~name:n ~times n)

let del t n = Mirror.remove_file t ("d/" ^ n)
let ren t a b = Mirror.move_file t ~src:("d/" ^ a) ~dst:("d/" ^ b)
let fid n = Option.get (Folder_id.of_string (Printf.sprintf "%012x-1" n))

let put_dir t n =
  incr seq;
  ignore (Mirror.record_folder ~durable:false t ("d/" ^ n) (fid !seq))

let del_dir t n = Mirror.remove_folder t ("d/" ^ n)
let ren_dir t a b = Mirror.move_folder t ~src:("d/" ^ a) ~dst:("d/" ^ b)

(* The local tree of folder d: each local name with the name it records. *)
let snapshot t =
  let dir = folder_dir t in
  List.sort compare
    (List.filter_map
       (fun local ->
         if Names.is_internal_local local || Names.is_temp_name local then None
         else Option.map (fun n -> (local, n)) (Local_names.name_at dir local))
       (Fs.readdir dir))

let show tree =
  String.concat ", "
    (List.map
       (fun (l, n) ->
         if l = n then String.escaped n else String.escaped n ^ "@esc")
       tree)

(* Whether this disk takes "A" for "a", learned by asking it. *)
let conflates =
  let d = Filename.concat root "probe" in
  Fs.mkdir_p d;
  Fs.durable_replace (Filename.concat d "a") "x";
  Sys.file_exists (Filename.concat d "A")

let a = "a"
let big_a = "A"
let acute_nfc = "\xc3\xa1"
let acute_nfd = "a\xcc\x81"
let names = [a; big_a; acute_nfc; acute_nfd]

(* On macOS the sweep only means something on a disk that conflates both ways. *)
let () =
  let d = Filename.concat root "probe" in
  Fs.durable_replace (Filename.concat d acute_nfc) "x";
  if Fs.is_macos then
    assert (conflates && Sys.file_exists (Filename.concat d acute_nfd))

let rec permutations = function
  | [] -> [[]]
  | l ->
      List.concat_map
        (fun x ->
          List.map (fun r -> x :: r) (permutations (List.filter (( <> ) x) l)))
        l

let rec subsets = function
  | [] -> [[]]
  | x :: r ->
      let s = subsets r in
      s @ List.map (fun l -> x :: l) s

let insert_at i x l =
  List.concat (List.mapi (fun j y -> if j = i then [x; y] else [y]) l)
  @ if i >= List.length l then [x] else []

(* Every ordering of the puts, then each with a transient name put and
   deleted, and each with a member arriving by a rename from another name. *)
let histories s =
  let others = List.filter (fun n -> not (List.mem n s)) names in
  List.concat_map
    (fun perm ->
      let puts = List.map (fun n -> `Put n) perm in
      let len = List.length puts in
      let transient =
        List.concat_map
          (fun z ->
            List.concat_map
              (fun i ->
                List.init
                  (len + 2 - i - 1)
                  (fun k ->
                    insert_at (i + 1 + k) (`Del z) (insert_at i (`Put z) puts)))
              (List.init (len + 1) Fun.id))
          others
      in
      let renamed =
        List.concat_map
          (fun z ->
            List.concat_map
              (fun target ->
                let i = Option.get (List.find_index (( = ) target) perm) in
                let puts =
                  List.map (fun n -> if n = target then `Put z else `Put n) perm
                in
                List.init (len - i) (fun k ->
                    insert_at (i + 1 + k) (`Ren (z, target)) puts))
              perm)
          others
      in
      (puts :: transient) @ renamed)
    (permutations s)

let run ~put ~del ~ren history =
  let t = fresh () in
  Fs.mkdir_p (folder_dir t);
  List.iter
    (function
      | `Put n -> put t n | `Del n -> del t n | `Ren (a, b) -> ren t a b)
    history;
  snapshot t

let convergence what ~put ~del ~ren =
  let ran = ref 0 and split = ref 0 in
  List.iter
    (fun s ->
      let trees =
        List.sort_uniq compare
          (List.map
             (fun h ->
               incr ran;
               run ~put ~del ~ren h)
             (histories s))
      in
      if List.length trees <> 1 then (
        incr split;
        p "  %s: state {%s} gave %d trees: %s\n" what
          (String.concat ", " (List.map String.escaped s))
          (List.length trees)
          (String.concat " | " (List.map show trees))))
    (subsets names);
  assert (!ran > 0);
  p "%s: %d histories over %d states, %d states with more than one tree\n" what
    !ran
    (List.length (subsets names))
    !split

let () =
  convergence "files" ~put ~del ~ren;
  convergence "folders" ~put:put_dir ~del:del_dir ~ren:ren_dir

(* The arrival that motivated this. *)
let () =
  let t = fresh () in
  put t "X of Y";
  put t "X Of Y";
  del t "X of Y";
  p "put of, put Of, delete of: %s\n" (show (snapshot t))

let same_as what ~fresh:f t =
  let ok = snapshot t = snapshot f in
  p "%s: %s\n" what (if ok then "same tree as the fresh history" else "differs");
  if not ok then
    p "  got %s, fresh %s\n" (show (snapshot t)) (show (snapshot f))

(* Review #1: a rename inside a class of three. *)
let () =
  let t = fresh () in
  put t "AB";
  put t "aB";
  ren t "AB" "ab";
  let f = fresh () in
  put f "aB";
  put f "ab";
  same_as "rename AB -> ab beside aB" ~fresh:f t;
  let t = fresh () in
  put_dir t "AB";
  put_dir t "aB";
  ren_dir t "AB" "ab";
  let f = fresh () in
  put_dir f "aB";
  put_dir f "ab";
  same_as "folder rename AB -> ab beside aB" ~fresh:f t

(* Review #4: a folder leaving its handle for a plain slot keeps a true name
   marker, and stays found. *)
let () =
  let t = fresh () in
  put_dir t "x:y";
  let id = Mirror.folder_id t "d/x:y" in
  ren_dir t "x:y" "z";
  let marker =
    Fs.read_file_opt
      (Filename.concat (Filename.concat (folder_dir t) "z") ".tsync-name")
  in
  p "move x:y -> z: id kept %b, name marker %s\n"
    (Mirror.folder_id t "d/z" = id && id <> None)
    (Option.value ~default:"none" marker)

(* Review #5: a key is found by its exact name, never by a slot it shares. *)
let () =
  let t = fresh () in
  put t "A";
  put t "a";
  let target n =
    match Mirror.file t ("d/" ^ n) with `File m -> m.name | _ -> "nothing"
  in
  p "a and A: d/a reads %s, d/A reads %s, d/b reads %s\n" (target "a")
    (target "A") (target "b")

(* Review #6: a probe a crash left behind is finished before a placement. *)
let () =
  let t = fresh () in
  put t "AB";
  put t "Ab";
  let dir = folder_dir t in
  Sys.remove (Filename.concat dir "AB");
  Fs.durable_replace (Filename.concat dir "AB") "";
  put t "ab";
  let f = fresh () in
  put f "Ab";
  put f "ab";
  same_as "put ab over a leftover probe" ~fresh:f t

(* Review #7: a placement that fails after its demotion undoes it. *)
let () =
  let t = fresh () in
  put t "of";
  let dir = folder_dir t in
  let before = snapshot t in
  match
    Local_names.place dir ~from:(Filename.concat dir "no such entry") "Of"
  with
    | _ -> p "placement of a missing entry succeeded\n"
    | exception Fail.E _ ->
        p "failed placement: tree unchanged %b\n" (snapshot t = before)

(* Review #8: a demotion whose handle another name holds is refused first. *)
let () =
  let t = fresh () in
  put t "of";
  let dir = folder_dir t in
  Fs.durable_replace
    (Filename.concat dir (Names.handle "of"))
    (Manifest.symlink ~name:"zz" ~times "zz").body;
  let before = snapshot t in
  let refused =
    match put t "Of" with
      | () -> false
      | exception Fail.E { kind = Exists; _ } -> true
  in
  assert (refused = conflates);
  assert ((not refused) || snapshot t = before);
  p
    "demotion onto a held handle: EXISTS where the disk conflates, nothing moved\n"

(* The demoted flag: set before a demotion, gone once nothing is demoted, never
   set in a folder without a collision. *)
let () =
  let t = fresh () in
  put t "a";
  put t "b";
  del t "a";
  assert (not (flagged t));
  put t "a";
  put t "A";
  assert (flagged t = conflates);
  del t "a";
  del t "A";
  assert (not (flagged t));
  p "demoted flag: only while a collision is filed, gone after it\n"

let () =
  p ".TSYNC-dir storable %b, .tsync-x storable %b, a storable %b\n"
    (Names.storable ".TSYNC-dir")
    (Names.storable ".tsync-x")
    (Names.storable "a")

(* Readers take no lock: while a writer demotes and promotes [of] over and over,
   a reader finds it every time, and never takes [Of] for it. *)
let () =
  let t = fresh () in
  put t "of";
  let stop = Atomic.make false in
  let reader n =
    Domain.spawn (fun () ->
        let reads = ref 0 and wrong = ref 0 in
        while not (Atomic.get stop) do
          incr reads;
          match Mirror.file t ("d/" ^ n) with
            | `File m when m.name = n -> ()
            | `Absent when n = "Of" -> ()
            | `File m ->
                incr wrong;
                Printf.eprintf "%s read %s\n%!" n m.name
            | `Absent | `Dir | `Corrupt ->
                incr wrong;
                Printf.eprintf "%s read nothing\n%!" n
            | exception e ->
                incr wrong;
                Printf.eprintf "%s raised %s\n%!" n (Printexc.to_string e)
        done;
        (!reads, !wrong))
  in
  let lower = reader "of" and upper = reader "Of" in
  for _ = 1 to 300 do
    put t "Of";
    del t "Of"
  done;
  Atomic.set stop true;
  let lr, lw = Domain.join lower and ur, uw = Domain.join upper in
  assert (lr > 0 && ur > 0);
  p
    "concurrent reads during 300 demotions: of wrong %d, Of wrong %d, both ran \
     %b\n"
    lw uw
    (lr > 0 && ur > 0)

(* The staged tree files every name at its handle. *)
let edit name =
  {
    Staged.name;
    size = 0;
    times;
    chunk_size = 4;
    content = Staged.Slots [||];
    state = Staged.Owed;
  }

let keys staged = List.sort compare (List.map fst (Staged.edits staged))

let () =
  incr seq;
  let staged =
    Staged.create ~cache_root:root (Domain_name.v (Printf.sprintf "h%d" !seq))
  in
  Staged.write staged "d/a" (edit "a");
  Staged.write staged "d/A" (edit "A");
  Staged.write staged "x:y/f" (edit "f");
  Staged.move_dir staged ~src:"x:y" ~dst:"z";
  p "staged: %s\n" (String.concat ", " (keys staged));
  (* Two writers making the same new directories at once. *)
  let writer n =
    Domain.spawn (fun () ->
        for i = 1 to 50 do
          Staged.write staged (Printf.sprintf "n%d/%s" i n) (edit n)
        done)
  in
  let w1 = writer "a" and w2 = writer "A" in
  Domain.join w1;
  Domain.join w2;
  p "staged concurrent writers: %d edits\n" (List.length (Staged.edits staged))

(* A staged tree filed by name, as before handles, moves to handles. *)
let () =
  incr seq;
  let domain = Printf.sprintf "h%d" !seq in
  let staged = Staged.create ~cache_root:root (Domain_name.v domain) in
  let base = Filename.concat (Filename.concat root domain) "staged/manifests" in
  let mirror = Filename.concat (Filename.concat root domain) "manifests" in
  Fs.mkdir_p (Filename.concat base "d");
  Fs.durable_replace (Filename.concat base "d/f") (Staged.encode (edit "f"));
  let esc = Names.handle "x:y" in
  Fs.mkdir_p (Filename.concat base esc);
  Fs.durable_replace
    (Filename.concat (Filename.concat base esc) (Names.handle "g:h"))
    (Staged.encode (edit "g:h"));
  Fs.mkdir_p (Filename.concat mirror esc);
  Fs.durable_replace
    (Filename.concat (Filename.concat mirror esc) ".tsync-name")
    "x:y";
  Staged.migrate_layout staged;
  p "migrated: %s; d/f found %b\n"
    (String.concat ", " (keys staged))
    (Staged.edit staged "d/f" <> None)

(* Code review: a staged directory left without edits is cleared out of a
   move's way; one with edits is never stripped of its name. *)
let () =
  incr seq;
  let staged =
    Staged.create ~cache_root:root (Domain_name.v (Printf.sprintf "h%d" !seq))
  in
  Staged.write staged "b/f" (edit "f");
  Staged.remove staged "b/f";
  Staged.write staged "a/g" (edit "g");
  Staged.move_dir staged ~src:"a" ~dst:"b";
  p "move onto a left-over staged directory: %s, b/g found %b\n"
    (String.concat ", " (keys staged))
    (Staged.edit staged "b/g" <> None);
  let refused =
    match Staged.write staged "b" (edit "b") with
      | () -> false
      | exception Fail.E { kind = Not_empty; _ } -> true
  in
  p "write over a staged directory with edits: refused %b, kept %s\n" refused
    (String.concat ", " (keys staged))

(* Code review: a migration repeated after a crash still finds the mirror's
   names below a directory it already moved. *)
let () =
  incr seq;
  let domain = Printf.sprintf "h%d" !seq in
  let staged = Staged.create ~cache_root:root (Domain_name.v domain) in
  let base = Filename.concat (Filename.concat root domain) "staged/manifests" in
  let mirror = Filename.concat (Filename.concat root domain) "manifests" in
  let moved = Filename.concat base (Names.handle "d") in
  let esc = Names.handle "x:y" in
  Fs.mkdir_p (Filename.concat moved esc);
  Fs.durable_replace (Filename.concat moved ".tsync-name") "d";
  Fs.durable_replace
    (Filename.concat (Filename.concat moved esc) (Names.handle "f"))
    (Staged.encode (edit "f"));
  Fs.mkdir_p (Filename.concat mirror ("d/" ^ esc));
  Fs.durable_replace
    (Filename.concat mirror ("d/" ^ esc ^ "/.tsync-name"))
    "x:y";
  Staged.migrate_layout staged;
  p "migration resumed: %s\n" (String.concat ", " (keys staged))

(* Code review: names that look internal in another case, listing probes, and
   moving an undecodable entry. *)
let () =
  let t = fresh () in
  put t ".Tsync-x";
  let dir = folder_dir t in
  Fs.durable_replace (Filename.concat dir "probe") "";
  Fs.durable_replace (Filename.concat dir "c") "not a manifest";
  Mirror.move_file t ~src:"d/c" ~dst:"d/x:y";
  let leftovers =
    List.filter
      (fun l -> not (Names.is_internal_local l))
      (List.sort compare (Fs.readdir dir))
  in
  p "names: %s; .Tsync-x at its handle %b; entries on disk %d\n"
    (String.concat ", " (Mirror.names t "d"))
    (Local_names.find dir ".Tsync-x" = Some (Names.handle ".Tsync-x"))
    (List.length leftovers)

let () = Fs.rm_rf root
