(* What a real object store has to do, asked of the real thing.

   The drivers' own tests are pure helpers -- encoding, date parsing -- and say
   so; the HTTP roundtrip was checked by hand against an emulator. That leaves
   the parts an emulator is worst at unverified, and {!Backend.put_if_absent} is
   exactly one of those: whether a write precondition is honoured, whether the
   loser is told who won, and whether the store's refusal classifies as an
   answer rather than a hiccup. A folder's identity is decided by winning one of
   these, so getting it wrong strands files.

   Driven through the registry rather than by naming a driver, so it exercises
   the path the product takes and builds whether or not s3 was linked.

   Each store is reached with the credentials CI holds and works under a prefix
   of its own, so concurrent runs cannot collide and a run cleans up after
   itself. Nothing here touches a domain. *)

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if ok then Printf.printf "    ok    %s\n%!" name
  else begin
    incr failures;
    Printf.printf "    FAIL  %s\n%!" name
  end

let env name = match Sys.getenv_opt name with Some "" | None -> None | v -> v

(* One prefix per run, so two runs -- or a run and a human -- never meet. *)
let run_prefix =
  Printf.sprintf "tsync/ci-%s/"
    (Option.value (env "GITHUB_RUN_ID")
       ~default:(string_of_int (Unix.getpid ())))

let suite name (module B : Backend.S) =
  let open Lwt.Syntax in
  Printf.printf "\n  %s\n%!" name;
  let key s = run_prefix ^ s in
  let* () =
    let* () = B.put ~key:(key "a") ~data:(Chunk.of_string "alpha") () in
    let* got = B.get ~key:(key "a") () in
    check "put then get returns what was written" (Chunk.to_string got = "alpha");
    let* got = B.get_opt ~key:(key "a") () in
    check "get_opt finds it" (Option.map Chunk.to_string got = Some "alpha");
    let* missing = B.get_opt ~key:(key "nope") () in
    check "get_opt of an absent key is None" (missing = None);
    let* head = B.head_opt ~key:(key "a") () in
    check "head_opt reports the size"
      (match head with Some e -> e.Backend.size = 5 | None -> false);
    let* head = B.head_opt ~key:(key "nope") () in
    check "head_opt of an absent key is None" (head = None);
    Lwt.return_unit
  in
  let* () =
    let* () = B.copy ~src_key:(key "a") ~dst_key:(key "b") () in
    let* got = B.get ~key:(key "b") () in
    check "copy duplicates the body" (Chunk.to_string got = "alpha");
    Lwt.return_unit
  in
  let* () =
    let* entries = B.list_prefix ~prefix:run_prefix () in
    let keys =
      List.map (fun (e : Backend.file_entry) -> e.Backend.key) entries
    in
    check "list_prefix sees both objects"
      (List.mem (key "a") keys && List.mem (key "b") keys);
    (* Not a page boundary -- that would want a thousand objects and the minutes
       to write them -- but it does prove the cap reaches the request. *)
    let* capped = B.list_prefix ~max_keys:1 ~prefix:run_prefix () in
    check "max_keys caps the listing" (List.length capped <= 1);
    Lwt.return_unit
  in
  (* The reason this file exists. *)
  let* () =
    let claim = key "claimed" in
    let* answers =
      Lwt_list.map_p
        (fun i ->
          B.put_if_absent ~key:claim
            ~data:(Chunk.of_string (Printf.sprintf "c%d" i))
            ())
        [1; 2; 3; 4; 5]
    in
    let answers = List.map Chunk.to_string answers in
    let* stored = B.get ~key:claim () in
    let stored = Chunk.to_string stored in
    check "five racing claims leave one body"
      (List.length (List.sort_uniq compare answers) = 1);
    check "every claimant is told what actually holds it"
      (List.for_all (fun a -> a = stored) answers);
    let* late = B.put_if_absent ~key:claim ~data:(Chunk.of_string "late") () in
    let late = Chunk.to_string late in
    check "a later claim is refused and told the holder"
      (late = stored && late <> "late");
    let* after = B.get ~key:claim () in
    check "and the holder is untouched" (Chunk.to_string after = stored);
    let* mine =
      B.put_if_absent ~key:(key "free") ~data:(Chunk.of_string "mine") ()
    in
    check "an unclaimed name answers with its own body"
      (Chunk.to_string mine = "mine");
    Lwt.return_unit
  in
  let* () =
    let+ caps = B.capabilities ~prefix:run_prefix () in
    (* Nothing is asserted about the values: a bucket may or may not serve
       shares. What matters is that asking works against the real service. *)
    ignore caps;
    check "capabilities answers" true
  in
  let* () =
    let* () = B.delete ~key:(key "a") () in
    let* got = B.get_opt ~key:(key "a") () in
    check "delete removes it" (got = None);
    let* () = B.delete_multi [key "b"; key "claimed"; key "free"] in
    let+ left = B.list_prefix ~prefix:run_prefix () in
    check "delete_multi clears the rest" (left = [])
  in
  (* Names that break an encoder rather than a store. A bulk delete names each key
     inside an XML document on both stores, so a key carrying a metacharacter is
     where a delete takes out the wrong object or none at all -- and none of that
     shows up with keys spelled [a] and [b]. The first three are what the document
     itself has to survive; the rest stress the signing and URI path.

     [+] and [%] are the two that have actually cost this project something, and
     they are the same bug the two ways round: [+] was signed as [%2B] and sent
     raw, [%] was signed as a literal and sent as the escape it looked like, so a
     key holding either answered 403. Both fixes are in the pinned aws-s3 fork
     and this is what holds them there. *)
  let special =
    [
      "amp-&-key";
      "angle-<tag>-key";
      "quotes-\"double\"-'single'";
      "plus+key";
      "percent-%2F-key";
      "hash#and?query";
      "space in key";
      "unicode-é-å-日本";
    ]
  in
  (* One check per name, and a raise caught per name: a store that refuses one
     spelling must say which, not take the rest of the suite down with it. The
     first version of this let the exception out, and a single 403 hid both the
     character that caused it and every check after it. *)
  let* survived =
    Lwt_list.filter_s
      (fun n ->
        Lwt.catch
          (fun () ->
            let* () =
              B.put ~key:(key ("bulk/" ^ n)) ~data:(Chunk.of_string n) ()
            in
            let+ got = B.get_opt ~key:(key ("bulk/" ^ n)) () in
            let ok = Option.map Chunk.to_string got = Some n in
            check (Printf.sprintf "key %S round-trips" n) ok;
            ok)
          (fun exn ->
            check
              (Printf.sprintf "key %S round-trips (raised: %s)" n
                 (Printexc.to_string exn))
              false;
            Lwt.return_false))
      special
  in
  (* The two things {!Gc} now leans on, neither of which an emulator is trusted
     for. Closing deletes off every copy the keys it discards on the main, so:

     - a key that is not there must not be an error. Every copy is sent the same
       list whether or not it holds each one, and a resumed run deletes a batch
       it may already have deleted.
     - a list longer than the store's own cap on a batch must all go. s3 and gcs
       both stop at 1000 per request and the driver pages past it; a paging bug
       leaves the tail behind, and nothing sweeps a copy any more.

     Done with a mostly-absent list, so pinning the paging costs a handful of
     writes rather than a thousand: the survivors sit at the front, on the
     boundary and past it, with the awkward names among them. *)
  let* () =
    let over = 1000 in
    let pad i = key (Printf.sprintf "bulk/absent-%04d" i) in
    let live = [key "bulk/first"; key "bulk/at-cap"; key "bulk/past-cap"] in
    let* () =
      Lwt_list.iter_s
        (fun k -> B.put ~key:k ~data:(Chunk.of_string "x") ())
        live
    in
    (* Only the spellings the store actually accepted: a name it refused above is
       not there to delete, and demanding it be gone would report the same defect
       twice under a name that does not describe it. *)
    let awkward = List.map (fun n -> key ("bulk/" ^ n)) survived in
    let batch =
      List.concat
        [
          [List.nth live 0];
          awkward;
          List.init (over - 2 - List.length awkward) pad;
          [List.nth live 1];
          List.init 200 (fun i -> pad (over + i));
          [List.nth live 2];
        ]
    in
    let* () = B.delete_multi batch in
    let+ left = B.list_prefix ~prefix:(run_prefix ^ "bulk/") () in
    check
      (Printf.sprintf "delete_multi of %d keys, mostly absent, clears every one"
         (List.length batch))
      (left = [])
  in
  Lwt.return_unit

let backend_of name fields =
  Backend.make ~backend_type:name ~get_field:(fun k -> List.assoc_opt k fields)

(* What a real store does with a request to check everything it holds.

   The half that is reachable from here is the client's: whether queueing lands
   real objects a real listing returns. The half that is not is the trigger — a
   terraform makes one notification per bucket, and this suite works under a CI
   prefix rather than a deployed stack. Nothing here is therefore evidence that
   the function ever runs. *)
let verify_suite name fields =
  let open Lwt.Syntax in
  let chunk_prefix = run_prefix ^ "chunks/" in
  let jobs = Chunk_layout.verify_jobs_prefix ~chunk_prefix in
  let (module On : Backend.S) = backend_of name fields in
  let* caps = On.capabilities ~prefix:chunk_prefix () in
  check "an object store reports that its chunks are checked"
    caps.Backend.verified;
  let* answer = On.verify_all ~chunk_prefix () in
  check "verify_all queues one request per shard"
    (answer = `Queued Chunk_layout.shards);
  let+ queued = On.list_prefix ~prefix:jobs () in
  check "the requests are objects the store lists back"
    (List.length queued = Chunk_layout.shards);
  check "and each names a shard"
    (List.for_all
       (fun (e : Backend.file_entry) ->
         Chunk_layout.shard_of_verify_job e.Backend.key <> None)
       queued)

(* Cleans up whatever the suite did not, including after a failure.

   Two prefixes, because sweep requests and markers are namespaced beside the
   store rather than under the domain: a run that only cleared [run_prefix]
   would leave one per shard behind in a real bucket, every time. *)
let sweep (module B : Backend.S) =
  let open Lwt.Syntax in
  let clear prefix =
    Lwt.catch
      (fun () ->
        let* entries = B.list_prefix ~prefix () in
        match
          List.map (fun (e : Backend.file_entry) -> e.Backend.key) entries
        with
          | [] -> Lwt.return_unit
          | keys -> B.delete_multi keys)
      (fun _ -> Lwt.return_unit)
  in
  let chunk_prefix = run_prefix ^ "chunks/" in
  let* () = clear run_prefix in
  let* () = clear (Chunk_layout.verify_jobs_prefix ~chunk_prefix) in
  clear (Chunk_layout.corrupted_prefix ~chunk_prefix)

let () =
  let linked = Backend.types () in
  let candidates =
    [
      ( "gcs",
        fun () ->
          match
            (env "TSYNC_CI_GCS_BUCKET", env "TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY")
          with
            | Some bucket, Some key ->
                Some [("bucket", bucket); ("serviceAccountKey", key)]
            | _ -> None );
      ( "s3",
        fun () ->
          match
            ( env "TSYNC_CI_S3_BUCKET",
              env "TSYNC_CI_S3_REGION",
              env "TSYNC_CI_S3_ACCESS_KEY_ID",
              env "TSYNC_CI_S3_SECRET_ACCESS_KEY" )
          with
            | Some bucket, Some region, Some id, Some secret ->
                Some
                  [
                    ("bucket", bucket);
                    ("region", region);
                    ("accessKeyId", id);
                    ("secretAccessKey", secret);
                  ]
            | _ -> None );
    ]
  in
  Printf.printf "conformance under %s\n%!" run_prefix;
  let ran = ref 0 in
  List.iter
    (fun (name, config) ->
      match (List.mem name linked, config ()) with
        | false, _ ->
            Printf.printf "\n  %s: not linked into this binary\n%!" name
        | true, None ->
            Printf.printf "\n  %s: no credentials in the environment\n%!" name
        | true, Some fields ->
            incr ran;
            let b = backend_of name fields in
            Lwt_main.run
              (Lwt.finalize
                 (fun () ->
                   Lwt.catch
                     (fun () ->
                       Lwt.bind (suite name b) (fun () ->
                           verify_suite name fields))
                     (fun exn ->
                       incr failures;
                       Printf.printf "    FAIL  %s raised: %s\n%!" name
                         (Printexc.to_string exn);
                       Lwt.return_unit))
                 (fun () -> sweep b)))
    candidates
  |> ignore;
  (* A run that verified nothing must not look like a run that passed: that is
     how a job goes green while testing an empty set. *)
  if !ran = 0 then begin
    Printf.printf
      "\nno store was both linked and configured -- nothing verified\n";
    exit 2
  end;
  Printf.printf "\n%d check(s), %d failure(s) across %d store(s)\n" !checks
    !failures !ran;
  exit (if !failures = 0 then 0 else 1)
