(* IPC-response snapshots: the actual JSON the daemon returns for the listing and
   change-feed actions, so the FileProvider contract — dir keys, logical size,
   content-hash etags, dirty state, and the changes_since / cursor delta with
   stale detection — is exercised directly. *)

open Test_runner

(* list_dir, whole and in pages: keys, logical size, etag (content hash),
   dirty state, and the order a page cursor resumes from. *)
let listing_scenarios : scenario list =
  [
    {
      name = "files: dirty then clean etag";
      steps =
        [
          Write { path = "a.txt"; content = "hello" };
          Write { path = "b.txt"; content = "world" };
        ];
    };
    (* Names that interleave, so ordering by name is distinguishable from
       listing every directory before every file. *)
    {
      name = "files and folders share one order";
      steps =
        [
          Mkdir "mid";
          Drain;
          Write { path = "aaa.txt"; content = "a" };
          Write { path = "zzz.txt"; content = "z" };
        ];
    };
    {
      name = "nested directories keyed as full paths";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/c.txt"; content = "nested" };
          Write { path = "top.txt"; content = "top" };
        ];
    };
    {
      name = "a folder this client cannot name is counted, not dropped";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/c.txt"; content = "nested" };
          Write { path = "top.txt"; content = "top" };
          Drain;
          ForgetFolderId "sub";
        ];
    };
    {
      name = "identical content shares an etag";
      steps =
        [
          Write { path = "x.txt"; content = "same bytes" };
          Drain;
          Write { path = "y.txt"; content = "same bytes" };
        ];
    };
  ]

(* changes_since / cursor: working delta, up-to-date, and stale detection. *)
let changes_scenarios : scenario list =
  [
    {
      name = "foreign put";
      steps = [Write { path = "a.txt"; content = "hi" }; Drain];
    };
    {
      name = "foreign mkdir then put";
      steps =
        [
          Mkdir "sub";
          Drain;
          Write { path = "sub/f.txt"; content = "deep" };
          Drain;
        ];
    };
    {
      name = "foreign delete";
      steps =
        [Write { path = "a.txt"; content = "x" }; Drain; Delete "a.txt"; Drain];
    };
    {
      name = "foreign rename";
      steps =
        [
          Write { path = "a.txt"; content = "x" };
          Drain;
          Rename { src = "a.txt"; dst = "b.txt" };
          Drain;
        ];
    };
    (* A removed folder is gone from the mirror by the time anyone reads the
       feed, so its id must be in the entry or a reader that knows folders by id
       cannot name it. On a rename the id is also what marks the two paths as one
       folder. *)
    {
      name = "foreign rmdir carries the folder id";
      steps = [Mkdir "gone"; Drain; Rmdir "gone"; Drain];
    };
    {
      name = "foreign dir rename carries the folder id";
      steps =
        [Mkdir "before"; Drain; Rename { src = "before"; dst = "after" }; Drain];
    };
  ]

(* A parent spelled as a storage key, which names the folder without saying it
   is one. The daemon names items by reference and answers this as it answers
   anything it cannot name, rather than guessing a kind. *)
let parent_ref_scenarios : scenario list =
  [
    {
      name = "create under a parent named by key is refused";
      steps =
        [
          Mkdir "sub";
          Drain;
          CreateUnder
            { parent = "tsync/test/manifests/sub"; name = "bykey.txt" };
        ];
    };
  ]

(* The daemon reporting on itself: what [tsync status] renders and what the
   http-proxy serves over /stats. *)
let stats_scenarios : scenario list =
  [
    {
      name = "after uploads: cache filled, nothing left unpublished";
      steps =
        [
          Write { path = "a.txt"; content = "hello" };
          Write { path = "sub/b.txt"; content = "world" };
        ];
    };
  ]

let () =
  print_endline "########## LISTING ##########";
  run_ipc listing_scenarios;
  print_endline "########## PARENT REFS ##########";
  run_ipc parent_ref_scenarios;
  print_endline "########## CHANGES ##########";
  run_ipc_changes changes_scenarios;
  print_endline "########## STATS ##########";
  run_stats stats_scenarios
