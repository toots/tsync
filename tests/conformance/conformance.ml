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
    let* () = B.put ~key:(key "a") ~data:"alpha" () in
    let* got = B.get ~key:(key "a") () in
    check "put then get returns what was written" (got = "alpha");
    let* got = B.get_opt ~key:(key "a") () in
    check "get_opt finds it" (got = Some "alpha");
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
    check "copy duplicates the body" (got = "alpha");
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
        (fun i -> B.put_if_absent ~key:claim ~data:(Printf.sprintf "c%d" i) ())
        [1; 2; 3; 4; 5]
    in
    let* stored = B.get ~key:claim () in
    check "five racing claims leave one body"
      (List.length (List.sort_uniq compare answers) = 1);
    check "every claimant is told what actually holds it"
      (List.for_all (fun a -> a = stored) answers);
    let* late = B.put_if_absent ~key:claim ~data:"late" () in
    check "a later claim is refused and told the holder"
      (late = stored && late <> "late");
    let* after = B.get ~key:claim () in
    check "and the holder is untouched" (after = stored);
    let* mine = B.put_if_absent ~key:(key "free") ~data:"mine" () in
    check "an unclaimed name answers with its own body" (mine = "mine");
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
  Lwt.return_unit

(* Cleans up whatever the suite did not, including after a failure. *)
let sweep (module B : Backend.S) =
  let open Lwt.Syntax in
  Lwt.catch
    (fun () ->
      let* entries = B.list_prefix ~prefix:run_prefix () in
      match
        List.map (fun (e : Backend.file_entry) -> e.Backend.key) entries
      with
        | [] -> Lwt.return_unit
        | keys -> B.delete_multi keys)
    (fun _ -> Lwt.return_unit)

let backend_of name fields =
  Backend.make ~backend_type:name ~get_field:(fun k -> List.assoc_opt k fields)

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
                     (fun () -> suite name b)
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
