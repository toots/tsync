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

open Check

let env name = match Sys.getenv_opt name with Some "" | None -> None | v -> v

(* Whether a verifier is deployed on this store's bucket, which decides both
   what the client may hand over and what the suite may expect to still be
   there. Read once so the backend field and the expectations cannot disagree. *)
let verify_function name =
  env
    (Printf.sprintf "TSYNC_CI_%s_VERIFY_FUNCTION" (String.uppercase_ascii name))

(* Folded by the runner; anywhere else they are noise, so they are emitted only
   where something reads them. A failure is annotated as well as printed: a
   group is collapsed by default, and a FAILED line inside one is easy to miss.
*)
let in_actions = Sys.getenv_opt "GITHUB_ACTIONS" = Some "true"
let grouped = ref false

let group name =
  if in_actions then begin
    if !grouped then print_string "::endgroup::\n";
    Printf.printf "::group::%s\n%!" name;
    grouped := true
  end
  else Check.case name

let group_end () =
  if in_actions && !grouped then begin
    Printf.printf "::endgroup::\n%!";
    grouped := false
  end

let check ?why name ok =
  let detail = if ok then None else Option.map (fun w -> w ()) why in
  Check.check ?why:(Option.map (fun d () -> d) detail) name ok;
  if (not ok) && in_actions then
    Printf.printf "::error::%s%s\n%!" name
      (match detail with None -> "" | Some d -> " -- " ^ d)

(* One prefix per run, so two runs -- or a run and a human -- never meet. *)
let run_prefix =
  Printf.sprintf "tsync/ci-%s/"
    (Option.value (env "GITHUB_RUN_ID")
       ~default:(string_of_int (Unix.getpid ())))

let suite name (module B : Backend.S) =
  let open Lwt.Syntax in
  let key s = run_prefix ^ s in
  let round_trip () =
    let* () = B.put ~key:(key "a") ~data:(Bigstring.of_string "alpha") () in
    let* got = B.get ~key:(key "a") () in
    check "put then get returns what was written" (Bigstring.to_string got = "alpha");
    let* got = B.get_opt ~key:(key "a") () in
    check "get_opt finds it" (Option.map Bigstring.to_string got = Some "alpha");
    let* missing = B.get_opt ~key:(key "nope") () in
    check "get_opt of an absent key is None" (missing = None);
    let* head = B.head_opt ~key:(key "a") () in
    check "head_opt reports the size"
      (match head with Some e -> e.Backend.size = 5 | None -> false);
    let* head = B.head_opt ~key:(key "nope") () in
    check "head_opt of an absent key is None" (head = None);
    Lwt.return_unit
  in
  let copying () =
    let* () = B.copy ~src_key:(key "a") ~dst_key:(key "b") () in
    let* got = B.get ~key:(key "b") () in
    check "copy duplicates the body" (Bigstring.to_string got = "alpha");
    Lwt.return_unit
  in
  let listing () =
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
  (* The second bulk verb, and the one whose failure is silent: a key wrongly
     answered absent writes a mirror missing that file, and nothing walks a copy
     afterwards to notice.

     Asked through {!Backend.Batched} rather than of the driver's own field, so
     a store that declares no batch is held to the same answers as one that
     does, and a driver that later grows one inherits the cases. *)
  let reading_many () =
    let module Bb = Backend.Batched (B) in
    let entry k = Backend.{ key = k; size = 5; last_modified = 0.; etag = None } in
    let asked = [entry (key "a"); entry (key "nope"); entry (key "b")] in
    let* answered = Bb.get_many ~entries:asked () in
    check "every key asked for is answered, in order"
      (List.map fst answered = List.map (fun e -> e.Backend.key) asked);
    check "a present key carries its body"
      (List.map (fun (_, b) -> Option.map Bigstring.to_string b) answered
      = [Some "alpha"; None; Some "alpha"]);
    (* Past whatever the store takes per request, so a driver that pages is
       exercised rather than trusted. *)
    let bulk = List.init 300 (fun i -> key (Printf.sprintf "many-%03d" i)) in
    let* () =
      Lwt_list.iter_p
        (fun k -> B.put ~key:k ~data:(Bigstring.of_string k) ())
        bulk
    in
    let* answered = Bb.get_many ~entries:(List.map entry bulk) () in
    check "a list longer than one request is still answered whole"
      (List.map fst answered = bulk
      && List.for_all
           (fun (k, b) -> Option.map Bigstring.to_string b = Some k)
           answered);
    let* () = B.delete_multi bulk in
    Lwt.return_unit
  in
  (* A body the size the product actually moves. Every other one here fits in a
     single socket read, which is the one size at which framing, content-length
     and reassembly cannot be wrong.

     Compared by hash rather than as strings, because the point of a chunk is
     that it never becomes one. *)
  let chunk_sized_body () =
    let size = Conf.default_chunk_size in
    let body =
      let buffer = Bigstring.create size in
      (* Position-dependent, so a slice arriving twice, out of order or not at
         all shows up; a constant fill survives all three. *)
      for i = 0 to size - 1 do
        Bigstringaf.unsafe_set buffer i (Char.chr (i * 31 land 0xff))
      done;
      buffer
    in
    let digest = Xxhash.hash_bigstring_hex body 0 in
    let big = key "big" in
    let* () = B.put ~key:big ~data:body () in
    let* got = B.get ~key:big () in
    check "a chunk-sized body comes back whole"
      (Bigstring.length got = size && Xxhash.hash_bigstring_hex got 0 = digest);
    let* head = B.head_opt ~key:big () in
    check "head_opt reports a chunk-sized object's size"
      (match head with Some e -> e.Backend.size = size | None -> false);
    (* A refused claim answers with the holder's body, so a chunk-sized one
       comes back down the same path a get does. *)
    let* held = B.put_if_absent ~key:big ~data:(Bigstring.of_string "small") () in
    check "a refused claim answers with the chunk-sized holder"
      (Bigstring.length held = size && Xxhash.hash_bigstring_hex held 0 = digest);
    let* () = B.delete ~key:big () in
    Lwt.return_unit
  in
  (* The reason this file exists. *)
  let racing_claims () =
    let claim = key "claimed" in
    let* answers =
      Lwt_list.map_p
        (fun i ->
          B.put_if_absent ~key:claim
            ~data:(Bigstring.of_string (Printf.sprintf "c%d" i))
            ())
        [1; 2; 3; 4; 5]
    in
    let answers = List.map Bigstring.to_string answers in
    let* stored = B.get ~key:claim () in
    let stored = Bigstring.to_string stored in
    check "five racing claims leave one body"
      (List.length (List.sort_uniq compare answers) = 1);
    check "every claimant is told what actually holds it"
      (List.for_all (fun a -> a = stored) answers);
    let* late = B.put_if_absent ~key:claim ~data:(Bigstring.of_string "late") () in
    let late = Bigstring.to_string late in
    check "a later claim is refused and told the holder"
      (late = stored && late <> "late");
    let* after = B.get ~key:claim () in
    check "and the holder is untouched" (Bigstring.to_string after = stored);
    let* mine =
      B.put_if_absent ~key:(key "free") ~data:(Bigstring.of_string "mine") ()
    in
    check "an unclaimed name answers with its own body"
      (Bigstring.to_string mine = "mine");
    Lwt.return_unit
  in
  let capabilities () =
    let+ caps = B.capabilities ~prefix:run_prefix () in
    (* Nothing is asserted about the values: a bucket may or may not serve
       shares. What matters is that asking works against the real service. *)
    ignore caps;
    check "capabilities answers" true
  in
  let deleting () =
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
  let awkward_names () =
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
    Lwt_list.filter_s
      (fun n ->
        Lwt.catch
          (fun () ->
            let* () =
              B.put ~key:(key ("bulk/" ^ n)) ~data:(Bigstring.of_string n) ()
            in
            let+ got = B.get_opt ~key:(key ("bulk/" ^ n)) () in
            let ok = Option.map Bigstring.to_string got = Some n in
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
  let bulk_delete survived =
    let over = 1000 in
    let pad i = key (Printf.sprintf "bulk/absent-%04d" i) in
    let live = [key "bulk/first"; key "bulk/at-cap"; key "bulk/past-cap"] in
    let* () =
      Lwt_list.iter_s
        (fun k -> B.put ~key:k ~data:(Bigstring.of_string "x") ())
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
  let section label f =
    group (Printf.sprintf "%s: %s" name label);
    f ()
  in
  let* () = section "round trips, heads and copies" round_trip in
  let* () = section "copying" copying in
  let* () = section "listing" listing in
  let* () = section "reading many at once" reading_many in
  let* () = section "a chunk-sized body" chunk_sized_body in
  let* () = section "racing claims" racing_claims in
  let* () = section "capabilities" capabilities in
  let* () = section "deleting" deleting in
  let* survived = section "awkward key names" awkward_names in
  section "bulk delete past the cap" (fun () -> bulk_delete survived)

let backend_of name fields =
  Backend.make ~backend_type:name
    ~get_field:(fun k -> List.assoc_opt k fields)
    ()

(* What a real store does with a request to check everything it holds.

   The half that is reachable from here is the client's: whether queueing lands
   real objects a real listing returns. The half that is not is the trigger — a
   terraform makes one notification per bucket, and this suite works under a CI
   prefix rather than a deployed stack. Nothing here is therefore evidence that
   the function ever runs. *)
let verify_suite name fields =
  let open Lwt.Syntax in
  group (Printf.sprintf "%s: whole-store verification requests" name);
  let chunk_prefix = run_prefix ^ "chunks/" in
  let jobs = Chunk_layout.verify_jobs_prefix ~chunk_prefix in
  let (module On : Backend.S) = backend_of name fields in
  let* caps = On.capabilities ~prefix:chunk_prefix () in
  check "an object store reports that its chunks are checked"
    caps.Backend.verified;
  let* answer = On.verify_all ~chunk_prefix () in
  check "verify_all queues one request per shard"
    (answer = `Queued Chunk_layout.shards);
  let* queued = On.list_prefix ~prefix:jobs () in
  (* A deployed function eats these as they arrive, so a complete listing is
     only the answer when nothing is listening. Asking for all of them against a
     live bucket is asking the function not to have run. *)
  (match verify_function name with
    | None ->
        check "the requests are objects the store lists back"
          (List.length queued = Chunk_layout.shards)
    | Some _ ->
        check "the requests are objects the store lists back, or already taken"
          (List.length queued <= Chunk_layout.shards));
  check "and each names a shard"
    (List.for_all
       (fun (e : Backend.file_entry) ->
         Chunk_layout.shard_of_job e.Backend.key <> None)
       queued);
  (* A collection's deletes go the same way, and the request carrying the keys
     is what stands in for the delete having happened — so that it lands, and
     reads back byte for byte, is the half of the contract reachable from here.

     An object store always takes one: the function that consumes them comes
     with the bucket, as the one that checks chunks does. *)
  let doomed =
    [chunk_prefix ^ "abb/" ^ String.make 16 'a' ^ "-" ^ String.make 16 'b']
  in
  let* answer =
    On.discard ~chunk_prefix ~run:"0001755300000000" ~name:"abb" ~keys:doomed ()
  in
  check "an object store takes a delete request" (answer = `Queued);
  let key =
    Chunk_layout.gc_job_key ~chunk_prefix ~run:"0001755300000000" "abb"
  in
  let+ body = On.get_opt ~key () in
  check "the delete request is an object the store hands back" (body <> None);
  check "carrying exactly the keys it was given"
    (Option.map (fun b -> Discard_job.decode (Bigstring.to_string b)) body
    = Some doomed)

(* The half a client cannot prove on its own: that something is listening.
   Everything above shows a request object lands and reads back; only the
   store's own notification and the function behind it turn one into a delete,
   and neither is reachable from here except by writing one and watching.

   Run only when the bucket is known to have a function deployed on it, because
   a bucket without one would have this wait out its timeout and report a fault
   where there is merely an absence. Told rather than probed: nothing a client
   can ask distinguishes "no function" from "function is broken", which is the
   whole reason this is worth having. *)
let live_delete_suite name (module B : Backend.S) =
  let open Lwt.Syntax in
  group (Printf.sprintf "%s: the deployed function" name);
  match
    env
      (Printf.sprintf "TSYNC_CI_%s_VERIFY_FUNCTION"
         (String.uppercase_ascii name))
  with
    | None ->
        step
          "NOT RUN: no function is deployed on this bucket \
           (TSYNC_CI_%s_VERIFY_FUNCTION unset -- scripts/setup_ci_secrets.sh)"
          (String.uppercase_ascii name);
        Lwt.return_unit
    | Some fn ->
        step "against the deployed function %s" fn;
        let chunk_prefix = run_prefix ^ "chunks/" in
        (* A real chunk, named the way one is: the function refuses anything
           that is not shaped like a chunk key under the requesting domain, so a
           made-up name would test the refusal rather than the delete. *)
        let body = Bigstring.of_string "conformance: a chunk to be collected" in
        let key = Chunk_layout.key_of_body body in
        let shard = String.sub key 0 Chunk_layout.fanout in
        let doomed = chunk_prefix ^ shard ^ "/" ^ key in
        let* () = B.put ~key:doomed ~data:body () in
        let* here = B.head_opt ~key:doomed () in
        check "the chunk to be collected is there to begin with" (here <> None);
        let* answer =
          B.discard ~chunk_prefix ~run:"0000000000001" ~name:shard
            ~keys:[doomed] ()
        in
        check "the store took the request" (answer = `Queued);
        (* Delivery is asynchronous and a cold function is slow, so this waits
           rather than checks once -- and fails on expiry, a poll that gave up
           quietly being worth nothing. *)
        let deadline = Unix.gettimeofday () +. 180. in
        let rec wait () =
          let* still = B.head_opt ~key:doomed () in
          if still = None then Lwt.return true
          else if Unix.gettimeofday () > deadline then Lwt.return false
          else
            let* () = Lwt_unix.sleep 5. in
            wait ()
        in
        let* gone = wait () in
        check "the function dropped the chunk the request named" gone;
        if not gone then
          step
            "nothing consumed it in 180s -- check the bucket's notification \
             and the function's logs";
        Lwt.return_unit

(* Cleans up whatever the suite did not, including after a failure.

   Three prefixes beside [run_prefix], because sweep requests, delete requests
   and markers are namespaced beside the store rather than under the domain: a
   run that only cleared [run_prefix] would leave one per shard behind in a real
   bucket, every time. *)
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
  let* () = clear (Chunk_layout.gc_jobs_prefix ~chunk_prefix) in
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
        | false, _ -> step "%s: not linked into this binary" name
        | true, None -> step "%s: no credentials in the environment" name
        | true, Some fields ->
            incr ran;
            let b = backend_of name fields in
            Lwt_main.run
              (Lwt.finalize
                 (fun () ->
                   Lwt.catch
                     (fun () ->
                       Lwt.bind (suite name b) (fun () ->
                           Lwt.bind (verify_suite name fields) (fun () ->
                               live_delete_suite name b)))
                     (fun exn ->
                       check
                         ~why:(fun () -> Printexc.to_string exn)
                         (name ^ " ran to completion")
                         false;
                       Lwt.return_unit))
                 (fun () -> sweep b)))
    candidates
  |> ignore;
  (* A run that verified nothing must not look like a run that passed: that is
     how a job goes green while testing an empty set. *)
  if !ran = 0 then begin
    group_end ();
    Printf.printf
      "\nno store was both linked and configured -- nothing verified\n";
    exit 2
  end;
  group_end ();
  step "across %d store(s)" !ran;
  report ()
