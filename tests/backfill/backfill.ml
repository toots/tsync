(* A backfill target is a converging copy filled from the write side: chunks as
   they are written, and a manifest only once every chunk it names is confirmed
   present. Each case prints what it did and then what the target holds, so the
   snapshot states the policy rather than just passing.

   Keys are printed by short label ([c0], [one]): the real ones are hex digests
   that say nothing here. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-backfill" ""
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

let case name = Printf.printf "\n=== %s\n" name
let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")

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

module Down : Backend.S = struct
  let fail () = Lwt.fail (Backend.Backend_error "down")
  let put ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
  let share_url ~prefix:_ () = Lwt.return_none
  let default_chunk_size ~prefix:_ () = Lwt.return_none
  let max_concurrency ~prefix:_ () = Lwt.return_none
end

let wrap ~inners ~target ~name : Backfill_backend.t =
  Backfill_backend.make ~chunk_prefix ~chunk_keys
    ~skip_prefixes:[journal_prefix; cursor_key]
    ~inners
    ~backfills:[{ Backfill_backend.name; backend = target }]

let () =
  let main = Local_backend.make ~root:main_root in
  let (module M : Backend.S) = main in
  let wrapped =
    wrap ~inners:[main]
      ~target:(Local_backend.make ~root:target_root)
      ~name:"target"
  in
  let (module B : Backend.S) = wrapped.Backfill_backend.backend in
  (* As the diagnosis endpoints report it. *)
  let lane = List.assoc "target" wrapped.Backfill_backend.lanes in
  (* The generic hook rather than [Backfill_backend.drain_all]: a target catches
     up only because [make] registered itself there. *)
  let drain () =
    let+ () = Backend.drain () in
    step "drain"
  in
  Lwt_main.run
    (let c0 = chunk 0 and c2 = chunk 2 and c4 = chunk 4 in
     let c6 = chunk 6 and c8 = chunk 8 in

     case "chunks written through the wrapper, then the manifest naming them";
     let* () = B.put ~key:c0 ~data:"aaaa" () in
     step "put chunk c0";
     let* () = B.put ~key:c2 ~data:"bbbb" () in
     step "put chunk c2";
     let* () =
       B.put ~key:(manifest_key "one") ~data:(manifest ~name:"one" [c0; c2]) ()
     in
     step "put manifest one [c0 c2]";
     let* () = drain () in
     dump_target ();

     case "the dedup hole: a manifest whose chunks were never written here";
     (* [Remote.chunk_exists] skips a chunk PUT when the source of truth already
        has it, so a copied file reaches the wrapper as a manifest alone. The
        manifest step must fetch c4 itself. *)
     let* () = M.put ~key:c4 ~data:"cccc" () in
     step "put chunk c4 straight to main, bypassing the wrapper";
     let* () =
       B.put ~key:(manifest_key "copy")
         ~data:(manifest ~name:"copy" [c0; c4])
         ()
     in
     step "put manifest copy [c0 c4]";
     let* () = drain () in
     dump_target ();

     case "a symlink names no chunks";
     let* () =
       B.put ~key:(manifest_key "link")
         ~data:(manifest ~symlink:"../one" ~name:"link" [])
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
         ~data:(manifest ~name:"orphan" [c6])
         ()
     in
     let* () = M.put ~key:c6 ~data:"dddd" () in
     step "put manifest orphan [c6] and chunk c6 straight to main";
     let* () =
       B.copy ~src_key:(manifest_key "orphan") ~dst_key:(manifest_key "orphan2")
         ()
     in
     step "copy orphan -> orphan2";
     let* () = drain () in
     dump_target ();

     case "sync bookkeeping is not a target's business";
     let* () = B.put ~key:(journal_prefix ^ "e1") ~data:"{}" () in
     step "put journal entry";
     let* () = B.put ~key:cursor_key ~data:"e1" () in
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
     let* () = B.put ~key:c0 ~data:"aaaa" () in
     step "put chunk c0 again";
     let* () = drain () in
     dump_target ();

     case "how far behind the target is, as reported for diagnosis";
     let* () =
       B.put ~key:(manifest_key "two") ~data:(manifest ~name:"two" [c0]) ()
     in
     let queued = lane () in
     step "queued right after a manifest put: %d (degraded %b)"
       queued.Backfill_backend.queued queued.Backfill_backend.degraded;
     let* () = drain () in
     let settled = lane () in
     step "queued once drained: %d (in flight %d, degraded %b)"
       settled.Backfill_backend.queued settled.Backfill_backend.in_flight
       settled.Backfill_backend.degraded;

     case "an unreachable target is logged, never fatal";
     let down = wrap ~inners:[main] ~target:(module Down) ~name:"down" in
     let (module D : Backend.S) = down.Backfill_backend.backend in
     let* () = D.put ~key:c8 ~data:"eeee" () in
     let* () =
       D.put ~key:(manifest_key "safe") ~data:(manifest ~name:"safe" [c8]) ()
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
     step "get chunk c2 = %S" d;
     let* none = B.get_opt ~key:(chunk 98) () in
     step "get_opt an absent chunk = %s"
       (match none with Some _ -> "some" | None -> "none");
     Lwt.return_unit)
