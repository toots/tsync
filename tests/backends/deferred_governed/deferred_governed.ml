(* What a deferred target does with the link's answer.

   A chunk forward is best-effort: the body is in hand, so it goes to the
   target now if the link has room, and is dropped for the manifest job to
   fetch later if not. The answer here is scripted rather than measured, so
   what is pinned is the contract alone: a refusal drops the forward without
   holding it, the job delivers every chunk regardless, and the question
   carries the body's own size. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "deferred_governed"
let main_root = Filename.concat root "main"
let log_dir = Filename.concat root "pending"
let chunk_prefix = "tsync/d/chunks/"
let journal_prefix = "tsync/d/journal/"
let manifest_prefix = "tsync/d/manifests/"
let cursor_key = Stored_key.in_space ~prefix:"tsync/d/" "cursor"
let hex n = Printf.sprintf "%016x" n

let chunk n =
  Stored_key.in_space ~prefix:chunk_prefix
    (Chunk_layout.relative_path (hex n ^ "-" ^ hex (n + 1)))

let manifest_key name = Stored_key.in_space ~prefix:manifest_prefix name

let manifest ~name chunks =
  let keys = List.map (fun k -> Filename.basename (Stored_key.to_string k)) chunks in
  Manifest.encode ~name
    ~size:(Int64.of_int (List.length keys * 4))
    ~chunk_size:4 ~mtime:0. ~h1:(hex 0) ~h2:(hex 1) ~symlink:None ~keys

let chunk_keys data =
  match Manifest.of_string data with
    | t -> List.init (Manifest.count t) (Manifest.key t)
    | exception _ -> []

let rec files_under d =
  if Sys.file_exists d && Sys.is_directory d then
    Sys.readdir d |> Array.to_list
    |> List.concat_map (fun e -> files_under (Filename.concat d e))
  else if Sys.file_exists d then [d]
  else []

let has_infix ~infix s =
  let n = String.length infix and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = infix || at (i + 1)) in
  at 0

let on target_root ~infix =
  List.length (List.filter (has_infix ~infix) (files_under target_root))

let chunks_on r = on r ~infix:"/chunks/"
let manifests_on r = on r ~infix:"/manifests/"
let owed name = List.length (files_under (Filename.concat log_dir name))

let target_for ~room_for ~main ~target ~name =
  let built = ref None in
  let spec ~source =
    let t =
      Domain_store_lwt.Deferred.make ~room_for ~name ~backend:target ~source
        ~chunk_prefix ~chunk_keys ~journal_prefix ~cursor_key
        ~excluded:(fun _ -> false)
        ~reads_reach:true ~root:log_dir ()
    in
    built := Some t;
    t
  in
  let composite =
    Domain_store_lwt.make
      ~mains:[{ Domain_store_lwt.name = "main"; backend = main }]
      ~targets:[spec] ~archives:[]
  in
  (composite, Option.get !built)

let quiet (module T : Domain_store_lwt.Deferred.S) ~name =
  Until.reached (fun () ->
      let s = T.stats () in
      s.Deferred.queued = 0 && s.Deferred.in_flight = 0 && owed name = 0)

let body = Bigstring.of_string "aaaa"

let () =
  let main = Fixture.local_store ~verify_writes:false main_root in
  Lwt_main.run
    (case "no room: a forward is dropped, not held, and the job still delivers";
     let t1 = Filename.concat root "t1" in
     let (module B), (module T) =
       target_for
         ~room_for:(fun ~bytes:_ -> false)
         ~main
         ~target:(Fixture.local_store ~verify_writes:false t1)
         ~name:"refused"
     in
     let chunks = [chunk 0; chunk 2; chunk 4] in
     let* () = Lwt_list.iter_s (fun key -> B.put ~key ~data:body ()) chunks in
     check "nothing in flight and nothing on the target"
       ~why:(fun () ->
         Printf.sprintf "in flight %d, chunks %d" (T.stats ()).Deferred.in_flight
           (chunks_on t1))
       ((T.stats ()).Deferred.in_flight = 0 && chunks_on t1 = 0);
     let* () =
       B.put ~key:(manifest_key "one")
         ~data:(Bigstring.of_string (manifest ~name:"one" chunks))
         ()
     in
     let* () = quiet (module T) ~name:"refused" in
     check "the manifest job fetched every dropped chunk"
       ~why:(fun () -> string_of_int (chunks_on t1))
       (chunks_on t1 = 3 && manifests_on t1 = 1);
     check "and owes nothing" (owed "refused" = 0);

     case "room: a forward goes straight through, ahead of any manifest";
     let t2 = Filename.concat root "t2" in
     let (module B), (module T) =
       target_for
         ~room_for:(fun ~bytes:_ -> true)
         ~main
         ~target:(Fixture.local_store ~verify_writes:false t2)
         ~name:"granted"
     in
     let* () =
       Lwt_list.iter_s (fun key -> B.put ~key ~data:body ()) [chunk 6; chunk 8]
     in
     let* () = Until.reached (fun () -> (T.stats ()).Deferred.in_flight = 0) in
     check "both chunks on the target, no manifest yet"
       ~why:(fun () ->
         Printf.sprintf "chunks %d manifests %d" (chunks_on t2) (manifests_on t2))
       (chunks_on t2 = 2 && manifests_on t2 = 0);

     case "the question carries the body's size, and is asked per forward";
     let t3 = Filename.concat root "t3" in
     let asked = ref [] in
     let (module B), (module T) =
       target_for
         ~room_for:(fun ~bytes ->
           asked := bytes :: !asked;
           (* Every other one. *)
           List.length !asked mod 2 = 1)
         ~main
         ~target:(Fixture.local_store ~verify_writes:false t3)
         ~name:"sized"
     in
     let chunks = [chunk 10; chunk 12; chunk 14] in
     let* () = Lwt_list.iter_s (fun key -> B.put ~key ~data:body ()) chunks in
     let* () = Until.reached (fun () -> (T.stats ()).Deferred.in_flight = 0) in
     check "asked once per chunk, with its four bytes"
       ~why:(fun () ->
         String.concat "," (List.map string_of_int (List.rev !asked)))
       (List.rev !asked = [4; 4; 4]);
     check "the two granted are there, the refused one is not"
       (chunks_on t3 = 2);
     let* () =
       B.put ~key:(manifest_key "three")
         ~data:(Bigstring.of_string (manifest ~name:"three" chunks))
         ()
     in
     let* () = quiet (module T) ~name:"sized" in
     check "and the job brings the third" (chunks_on t3 = 3);

     report ~expected:7 ();
     Lwt.return_unit)
