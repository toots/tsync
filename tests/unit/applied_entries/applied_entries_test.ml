(* Keeping the journal entries this client has already handled.

   The questions that matter are the ones the published journal answers by
   going back to the store: what came after an anchor, what the newest and
   oldest kept are, and when an anchor can no longer be bridged. A shard
   boundary and a torn line are here because both are ordinary — one happens
   every month, the other whenever two writers meet. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "applied-entries"
let cache_root = Filename.concat root "cache"
let domain_name = "testdom"
let uuid = "aaaaaaaaaaaaaaaa"

(* 2026-08-31 and 2026-09-02 UTC: two months, so the shard boundary is crossed
   by construction rather than by whenever the suite happens to run. *)
let august = 1788134400000L
let september = 1788307200000L

let key ms =
  match Journal.Entry_key.of_string (Printf.sprintf "%013Ld-%s" ms uuid) with
    | Some k -> k
    | None -> failwith "test entry key did not parse"

let note ?now k ops = Applied_entries.note ?now ~cache_root ~domain_name k ops
let head () = Applied_entries.head ~cache_root ~domain_name

let since ?since ~limit () =
  Applied_entries.since ~cache_root ~domain_name ?since ~limit ()

let shown (k, ops) =
  Printf.sprintf "%s %s"
    (Journal.Entry_key.to_string k)
    (Yojson.Basic.to_string (`List (List.map Journal.to_json ops)))

let show = function
  | None -> step "anchor gone"
  | Some page ->
      List.iter (fun e -> step "%s" (shown e)) page.Applied_entries.entries;
      step "more: %b" page.Applied_entries.more

let entries = function
  | None -> []
  | Some page -> List.map fst page.Applied_entries.entries

let names () =
  let+ names =
    Io_lwt.Fs.readdir_list_quiet
      (Cache_layout.applied_dir ~cache_root domain_name)
  in
  List.sort compare names

let a = key august
let b = key (Int64.add august 1L)
let c = key september

(* Handled in August and September: the shard is the handling time. *)
let in_august = Int64.to_float august /. 1000.
let in_september = Int64.to_float september /. 1000.

let main () =
  case "an entry is kept under the key that already names it";
  let* () = note ~now:in_august a [`Mkdir ("photos", Some "f1")] in
  let* () = note ~now:in_august b [`Put ("photos/one.jpg", 1024L)] in
  let* page = since ~limit:10 () in
  show page;
  check "every entry noted is read back" (List.length (entries page) = 2);
  check "oldest first" (entries page = [a; b]);
  check "and nothing claims to follow them"
    (match page with Some p -> not p.Applied_entries.more | None -> false);

  case "an anchor is exclusive, and a limit says there is more";
  let* page = since ~since:a ~limit:10 () in
  show page;
  check "the anchor's own entry is not repeated" (entries page = [b]);
  let* page = since ~limit:1 () in
  check "a full page says another would answer"
    (match page with Some p -> p.Applied_entries.more | None -> false);
  check "and holds exactly the limit" (List.length (entries page) = 1);

  case "the head is the entry handled last";
  let* h = head () in
  check "head is the newest kept" (h = Some b);

  case "a shard boundary is crossed by the calendar, not by the reader";
  let* () =
    note ~now:in_september c
      [
        `Rename
          {
            Journal.dst = "photos/two.jpg";
            src = "photos/one.jpg";
            size = Some 1024L;
            is_dir = false;
            id = None;
          };
      ]
  in
  let* files = names () in
  step "shards: %s" (String.concat " " files);
  check "one shard per month" (files = ["2026-08.log"; "2026-09.log"]);
  let* page = since ~since:a ~limit:10 () in
  show page;
  check "a read crosses into the next shard" (entries page = [b; c]);
  let* h = head () in
  check "head follows into it" (h = Some c);

  case "a rename survives the round trip whole";
  let* page = since ~since:b ~limit:10 () in
  check "both ends of the move are kept"
    (match page with
      | Some { Applied_entries.entries = [(_, [`Rename r])]; _ } ->
          r.Journal.dst = "photos/two.jpg" && r.Journal.src = "photos/one.jpg"
      | _ -> false);

  (* A peer's entry minted before [c] but handled after it: what a slow upload
     or a record published after a crash looks like. It follows [c] in this log,
     and a reader anchored at [c] must be given it. *)
  case "an entry handled late with an older key still follows the anchor";
  let late = key (Int64.add august 2L) in
  let* () = note ~now:in_september late [`Put ("photos/late.jpg", 8L)] in
  let* page = since ~since:c ~limit:10 () in
  show page;
  check "the reader is given it" (entries page = [late]);
  let* h = head () in
  check "and it is the head, whatever its key says" (h = Some late);

  case "a line one writer tore does not stop the reader";
  let torn =
    Filename.concat
      (Cache_layout.applied_dir ~cache_root domain_name)
      "2026-09.log"
  in
  (* What a writer that died mid-record leaves: its own leading newline, then
     as much of the record as reached the disk. *)
  let* body = Io_lwt.Fs.read_file_opt torn in
  let* () =
    Io_lwt.Fs.atomic_write torn
      (Option.value body ~default:"" ^ "\n0000000000000-hal")
  in
  let* () =
    note ~now:in_september
      (key (Int64.add september 1L))
      [`Delete "photos/two.jpg"]
  in
  let* page = since ~since:c ~limit:10 () in
  show page;
  check "the entries around it still read" (List.length (entries page) = 2);

  case "an anchor no longer kept cannot be bridged";
  let* shards, bytes =
    Applied_entries.prune ~cache_root ~domain_name ~keep_days:0
      ~keep_bytes:1_000_000
  in
  step "pruned %d shard(s)" shards;
  check "a sweep says what it took" (shards = 2 && bytes > 0);
  let* page = since ~since:a ~limit:10 () in
  show page;
  check "which is what stales an anchor" (page = None);

  report ~expected:16 ();
  Lwt.return_unit

let () =
  Lwt_main.run (main ());
  Scratch.cleanup root
