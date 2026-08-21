(* A backfill target is a converging copy filled from the write side: chunks as
   they are written, and a manifest only once every chunk it names is confirmed
   present. Each case prints what it did and then what the target holds, so the
   snapshot states the policy rather than just passing.

   Keys are printed by short label ([c0], [one]): the real ones are hex digests
   that say nothing here. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "backfill"
let main_root = Filename.concat root "main"
let target_root = Filename.concat root "target"
let chunk_prefix = "tsync/d/chunks/"
let journal_prefix = "tsync/d/journal/"
let cursor_key = "tsync/d/cursor"
let manifest_prefix = "tsync/d/manifests/"
let labels : (string * string) list ref = ref []
let hex n = Printf.sprintf "%016x" n

(* A chunk key is ["<16 hex>-<16 hex>"]; only distinctness matters. *)
let chunk n =
  let key =
    chunk_prefix ^ Chunk_layout.relative_path (hex n ^ "-" ^ hex (n + 1))
  in
  labels := (key, Printf.sprintf "c%d" n) :: !labels;
  key

let manifest_key name = manifest_prefix ^ name

let label key =
  match List.assoc_opt key !labels with
    | Some l -> "chunk " ^ l
    | None ->
        if key = cursor_key then "cursor"
        else if String.starts_with ~prefix:journal_prefix key then "journal"
        else if String.starts_with ~prefix:manifest_prefix key then
          "manifest "
          ^ String.sub key
              (String.length manifest_prefix)
              (String.length key - String.length manifest_prefix)
        else key

(* A symlink is a chunkless manifest, which the chunk step must tolerate. *)
let manifest ?symlink ~name chunks =
  let keys = List.map Filename.basename chunks in
  Chunk_table.encode ~name
    ~size:(Int64.of_int (List.length keys * 4))
    ~chunk_size:4 ~mtime:0. ~h1:(hex 0) ~h2:(hex 1) ~symlink ~keys

let chunk_keys data =
  match Chunk_table.of_string data with
    | t -> List.init (Chunk_table.count t) (Chunk_table.key t)
    | exception _ -> []

let keys_under root =
  let rec walk dir =
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun e ->
        let p = Filename.concat dir e in
        if Sys.is_directory p then walk p else [p])
  in
  if Sys.file_exists root then
    List.sort compare
      (List.map
         (fun p ->
           String.sub p
             (String.length root + 1)
             (String.length p - String.length root - 1))
         (walk root))
  else []

let dump_target () =
  print_endline "--- target";
  match keys_under target_root with
    | [] -> print_endline "  (empty)"
    | ks -> List.iter (fun k -> Printf.printf "  %s\n" (label k)) ks

module Down = Doubles.Down (struct
  let why = "down"
end)

(* A plain {!Deferred.make}: a backfill target is the one reads never reach, and
   so has no use for the journal or cursor either. The composite and the target
   both come back, since the target is what says how far behind it is. *)
let wrap ~inners ~target ~name =
  let built = ref None in
  let spec ~source =
    let d =
      Deferred.make ~name ~backend:target ~source ~chunk_prefix ~chunk_keys
        ~journal_prefix ~cursor_key
        ~root:(Filename.concat root "pending")
        ()
    in
    built := Some d;
    d
  in
  let composite =
    Domain_store.make
      ~mains:
        (List.mapi
           (fun i backend ->
             { Domain_store.name = Printf.sprintf "main%d" i; backend })
           inners)
      ~targets:[spec] ~archives:[]
  in
  (composite, Option.get !built)

let () =
  let main =
    Backend.make ~backend_type:"local"
      ~get_field:(function
        | "verifyWrites" -> Some "false" | _ -> Some main_root)
      ()
  in
  let (module M : Backend.S) = main in
  let composite, (module T : Deferred.S) =
    wrap ~inners:[main]
      ~target:
        (Backend.make ~backend_type:"local"
           ~get_field:(function
             | "verifyWrites" -> Some "false" | _ -> Some target_root)
           ())
      ~name:"target"
  in
  let (module B : Backend.S) = composite in
  (* As the diagnosis endpoints report it. *)
  let owed = T.stats in
  (* The generic hook rather than [Domain_store.drain]: a target catches up only
     because [make] registered itself there. *)
  let drain () =
    let+ () = Backend.drain () in
    step "drain"
  in
  Lwt_main.run
    (let c0 = chunk 0 and c2 = chunk 2 and c4 = chunk 4 in
     let c6 = chunk 6 and c8 = chunk 8 in

     case "chunks written through the wrapper, then the manifest naming them";
     let* () = B.put ~key:c0 ~data:(Chunk.of_string "aaaa") () in
     step "put chunk c0";
     let* () = B.put ~key:c2 ~data:(Chunk.of_string "bbbb") () in
     step "put chunk c2";
     let* () =
       B.put ~key:(manifest_key "one")
         ~data:(Chunk.of_string (manifest ~name:"one" [c0; c2]))
         ()
     in
     step "put manifest one [c0 c2]";
     let* () = drain () in
     dump_target ();

     case "the dedup hole: a manifest whose chunks were never written here";
     (* [Remote.chunk_exists] skips a chunk PUT when the source of truth already
        has it, so a copied file reaches the wrapper as a manifest alone. The
        manifest step must fetch c4 itself. *)
     let* () = M.put ~key:c4 ~data:(Chunk.of_string "cccc") () in
     step "put chunk c4 straight to main, bypassing the wrapper";
     let* () =
       B.put ~key:(manifest_key "copy")
         ~data:(Chunk.of_string (manifest ~name:"copy" [c0; c4]))
         ()
     in
     step "put manifest copy [c0 c4]";
     let* () = drain () in
     dump_target ();

     case "a symlink names no chunks";
     let* () =
       B.put ~key:(manifest_key "link")
         ~data:(Chunk.of_string (manifest ~symlink:"../one" ~name:"link" []))
         ()
     in
     step "put manifest link -> ../one";
     let* () = drain () in
     dump_target ();

     case "rename: copy then delete, in that order on the target too";
     let* () =
       B.copy ~src_key:(manifest_key "one") ~dst_key:(manifest_key "moved") ()
     in
     step "copy one -> moved";
     let* () = B.delete ~key:(manifest_key "one") () in
     step "delete one";
     let* () = drain () in
     dump_target ();

     case "copy whose source the target never had";
     (* Rebuilt from the authoritative copy of the destination rather than lost. *)
     let* () =
       M.put ~key:(manifest_key "orphan")
         ~data:(Chunk.of_string (manifest ~name:"orphan" [c6]))
         ()
     in
     let* () = M.put ~key:c6 ~data:(Chunk.of_string "dddd") () in
     step "put manifest orphan [c6] and chunk c6 straight to main";
     let* () =
       B.copy ~src_key:(manifest_key "orphan") ~dst_key:(manifest_key "orphan2")
         ()
     in
     step "copy orphan -> orphan2";
     let* () = drain () in
     dump_target ();

     case "sync bookkeeping is not a target's business";
     let* () =
       B.put ~key:(journal_prefix ^ "e1") ~data:(Chunk.of_string "{}") ()
     in
     step "put journal entry";
     let* () = B.put ~key:cursor_key ~data:(Chunk.of_string "e1") () in
     step "put cursor";
     let* () = drain () in
     let on r k = match keys_under r with ks -> List.mem k ks in
     step "journal on main: %b, on target: %b"
       (on main_root (journal_prefix ^ "e1"))
       (on target_root (journal_prefix ^ "e1"));
     step "cursor on main: %b, on target: %b" (on main_root cursor_key)
       (on target_root cursor_key);
     dump_target ();

     case "a deleted chunk is pushed again when it is written again";
     (* The dedup memo must not outlive the object it remembers. *)
     let* () = B.delete ~key:c0 () in
     step "delete chunk c0";
     let* () = drain () in
     dump_target ();
     let* () = B.put ~key:c0 ~data:(Chunk.of_string "aaaa") () in
     step "put chunk c0 again";
     let* () = drain () in
     dump_target ();

     case "how far behind the target is, as reported for diagnosis";
     let* () =
       B.put ~key:(manifest_key "two")
         ~data:(Chunk.of_string (manifest ~name:"two" [c0]))
         ()
     in
     let queued = owed () in
     step "queued right after a manifest put: %d (degraded %b)"
       queued.Deferred.queued queued.Deferred.degraded;
     let* () = drain () in
     let settled = owed () in
     step "queued once drained: %d (in flight %d, degraded %b)"
       settled.Deferred.queued settled.Deferred.in_flight
       settled.Deferred.degraded;

     case "an unreachable target is logged, never fatal";
     let down, _ = wrap ~inners:[main] ~target:(module Down) ~name:"down" in
     let (module D : Backend.S) = down in
     let* () = D.put ~key:c8 ~data:(Chunk.of_string "eeee") () in
     let* () =
       D.put ~key:(manifest_key "safe")
         ~data:(Chunk.of_string (manifest ~name:"safe" [c8]))
         ()
     in
     let* () =
       D.copy ~src_key:(manifest_key "safe") ~dst_key:(manifest_key "safe2") ()
     in
     let* () = D.delete ~key:(manifest_key "safe2") () in
     step "put chunk c8, put manifest safe, copy safe -> safe2, delete safe2";
     let* () = drain () in
     let* h = M.head_opt ~key:(manifest_key "safe") () in
     step "manifest safe on main: %b" (h <> None);
     let* h = M.head_opt ~key:c8 () in
     step "chunk c8 on main: %b" (h <> None);

     case "reads never consult a target";
     let* d = B.get ~key:c2 () in
     step "get chunk c2 = %S" (Chunk.to_string d);
     let* none = B.get_opt ~key:(chunk 98) () in
     step "get_opt an absent chunk = %s"
       (match none with Some _ -> "some" | None -> "none");
     Lwt.return_unit)
