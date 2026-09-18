(* A replica while the main is not there.

   It is a copy of what the main holds, so written on its own it holds something
   nobody can check against the source of truth. Every verb is tried against a
   main that has gone, and the replica is read back whole after each: what it
   holds, byte for byte, is the assertion, along with what is still owed to it.

   The main fails the way a lost link does, so nothing here is a store saying
   no: a refusal ends a write for other reasons than the ones being pinned. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "main-down"
let main_root = Filename.concat root "main"
let replica_root = Filename.concat root "replica"
let log_dir = Filename.concat root "pending"
let chunk_prefix = "tsync/d/chunks/"
let journal_prefix = "tsync/d/journal/"
let cursor_key = Stored_key.in_space ~prefix:"tsync/d/" "cursor"
let manifest_key name = Stored_key.in_space ~prefix:"tsync/d/manifests/" name

let chunk_key =
  Stored_key.in_space ~prefix:chunk_prefix
    (Chunk_layout.relative_path (Printf.sprintf "%016x-%016x" 1 2))

let local root =
  Backend_lwt.make ~backend_type:"local"
    ~get_field:(function "verifyWrites" -> Some "false" | _ -> Some root)
    ()

(* Every verb goes while [up] and fails as a link does while not, reads
   included: what a target still owes it re-reads from here. *)
let main_up = ref true
let asked_while_down = ref 0

let main : (module Backend_lwt.Store) =
  let (module Real : Backend_lwt.Store) = local main_root in
  (module struct
    include Real

    let gate op f =
      if !main_up then f ()
      else begin
        incr asked_while_down;
        Lwt.fail (Retry.failed ~kind:Retry.Transient ~op "link is down")
      end

    let put ~key ~data () = gate "put" (Real.put ~key ~data)

    let put_if_absent ~key ~data () =
      gate "put_if_absent" (Real.put_if_absent ~key ~data)

    let get ~key () = gate "get" (Real.get ~key)
    let get_opt ~key () = gate "get_opt" (Real.get_opt ~key)
    let head_opt ~key () = gate "head_opt" (Real.head_opt ~key)
    let delete ~key () = gate "delete" (Real.delete ~key)

    let delete_multi keys =
      gate "delete_multi" (fun () -> Real.delete_multi keys)

    let copy ~src_key ~dst_key () = gate "copy" (Real.copy ~src_key ~dst_key)
    let get_many = None
    let list_many = None
    let local_path = None
  end)

let replica_up = ref true

let replica : (module Backend_lwt.Store) =
  let (module Real : Backend_lwt.Store) = local replica_root in
  (module struct
    include Real

    let put ~key ~data () =
      if !replica_up then Real.put ~key ~data ()
      else
        Lwt.fail (Retry.failed ~kind:Retry.Transient ~op:"put" "link is down")
  end)

let rec files dir =
  if not (Sys.file_exists dir) then []
  else
    List.concat_map
      (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then files path else [path])
      (List.sort compare (Array.to_list (Sys.readdir dir)))

let read path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* The whole store, contents included: a key that is still there with other
   bytes in it is as much a write as a new one. *)
let held root =
  List.map
    (fun path ->
      ( String.sub path
          (String.length root + 1)
          (String.length path - String.length root - 1),
        read path ))
    (files root)

let show_replica () =
  match held replica_root with
    | [] -> step "replica holds nothing"
    | l -> List.iter (fun (k, v) -> step "replica holds %s = %S" k v) l

let owed () = List.length (files (Filename.concat log_dir "replica"))

let attempt what write =
  let+ said =
    Lwt.catch
      (fun () ->
        let+ () = write () in
        "done")
      (fun exn -> Lwt.return ("failed: " ^ Retry.reason exn))
  in
  step "%s -> %s" what said

let wait_until ?(bound = 30.) what condition =
  let deadline = Unix.gettimeofday () +. bound in
  let rec go () =
    if condition () then Lwt.return_unit
    else if Unix.gettimeofday () > deadline then begin
      step "gave up waiting for %s" what;
      Lwt.return_unit
    end
    else
      let* () = Lwt_unix.sleep 0.02 in
      go ()
  in
  go ()

let () =
  let target = ref None in
  let spec ~source =
    let t =
      Domain_store_lwt.Deferred.make ~name:"replica" ~backend:replica ~source
        ~chunk_prefix
        ~chunk_keys:(fun _ -> [])
        ~journal_prefix ~cursor_key
        ~excluded:(fun _ -> false)
        ~reads_reach:true ~root:log_dir ()
    in
    target := Some t;
    t
  in
  let (module Domain : Backend_lwt.Store) =
    Domain_store_lwt.make
      ~mains:[{ Domain_store_lwt.name = "main"; backend = main }]
      ~targets:[spec] ~archives:[]
  in
  let (module Target : Domain_store_lwt.Deferred.S) = Option.get !target in
  let settled () =
    wait_until "the replica to be owed nothing" (fun () ->
        let s = Target.stats () in
        s.Deferred.queued = 0 && s.Deferred.in_flight = 0 && owed () = 0)
  in
  let body s = Bigstring.of_string s in
  Lwt_main.run
    (case "both there: a write reaches the replica, behind the main";
     let* () = Domain.put ~key:(manifest_key "kept") ~data:(body "one") () in
     let* () = Domain.put ~key:chunk_key ~data:(body "chunk") () in
     let* () = settled () in
     show_replica ();
     let before = held replica_root in
     check "which is what the rest of this is measured against" (before <> []);

     case "the main goes: every verb, and the replica after all of them";
     main_up := false;
     let* () =
       attempt "put" (Domain.put ~key:(manifest_key "new") ~data:(body "two"))
     in
     let* () =
       attempt "put over what is there"
         (Domain.put ~key:(manifest_key "kept") ~data:(body "changed"))
     in
     let* () =
       attempt "put a chunk"
         (Domain.put
            ~key:
              (Stored_key.in_space ~prefix:chunk_prefix
                 (Chunk_layout.relative_path (Printf.sprintf "%016x-%016x" 3 4)))
            ~data:(body "chunk two"))
     in
     let* () =
       attempt "put_if_absent" (fun () ->
           let+ (_ : Bigstring.t) =
             Domain.put_if_absent ~key:(manifest_key "claim") ~data:(body "x")
               ()
           in
           ())
     in
     let* () =
       attempt "delete" (fun () ->
           let+ (_ : bool) = Domain.delete ~key:(manifest_key "kept") () in
           ())
     in
     let* () =
       attempt "delete_multi" (fun () ->
           Domain.delete_multi [manifest_key "kept"; chunk_key])
     in
     let* () =
       attempt "copy"
         (Domain.copy ~src_key:(manifest_key "kept")
            ~dst_key:(manifest_key "copied"))
     in
     show_replica ();
     check "the replica is byte for byte what it was"
       (held replica_root = before);
     check "and is owed nothing, none of those having happened"
       ((Target.stats ()).Deferred.queued = 0 && owed () = 0);

     case "a write the main took, still owed when the main goes";
     main_up := true;
     replica_up := false;
     let* () = Domain.put ~key:(manifest_key "late") ~data:(body "three") () in
     let* () = wait_until "the job to be owed" (fun () -> owed () > 0) in
     main_up := false;
     asked_while_down := 0;
     replica_up := true;
     (* The job carries no body: it goes back to the main for one, which is what
        stops a replica being filled from anything else. *)
     let* () =
       wait_until "the job to be tried again" (fun () -> !asked_while_down > 0)
     in
     step "tried again with the main gone: %b" (!asked_while_down > 0);
     show_replica ();
     check "the replica is still what it was" (held replica_root = before);
     check "and the write is still owed" (owed () > 0);

     case "the main comes back";
     main_up := true;
     let* () = settled () in
     show_replica ();
     check "what was owed has landed"
       (List.mem_assoc "tsync/d/manifests/late" (held replica_root));
     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:6 ()
