(* Whole-store verification (spec 05 §4.10 verify, object-store-common §3, §5).
   The copy is a local store standing in for a bucket, and the function a
   stand-in that checks a shard as lambda/verify.py verify_shard does; it can
   be switched off to play a function that stopped being notified. *)

open Tsync_core
open Tsync_store
open Tsync_gc

let p fmt = Printf.printf fmt
let d = Domain_name.v "d"

let check_shard (inner : Store.t) request =
  match Key.parse_verify_job request with
    | Some (_, shard) ->
        List.iter
          (fun (e : Store.entry) ->
            match (Key.chunk_of e.key, inner.get_opt e.key) with
              | Some c, Some b
                when not (Chunk_key.equal (Chunk_key.of_bigstring b) c) ->
                  inner.put (Key.marker d c) (Bigstring.of_string "{}")
              | _ -> ())
          (inner.list_prefix (Key.shard_prefix d shard));
        ignore (inner.delete request)
    | None -> ignore (inner.delete request)

(* [at_once] consumes each request inside its put, so what was written is gone
   before anyone looks. *)
let bucket ~function_on ~at_once (inner : Store.t) =
  let notify key =
    if Atomic.get function_on then
      if Key.parse_verify_job key <> None then
        if Atomic.get at_once then check_shard inner key
        else Rt.spawn ~name:"bucket function" (fun () -> check_shard inner key)
      else if Key.parse_discard_job key <> None then
        Rt.spawn ~name:"bucket function" (fun () -> ignore (inner.delete key))
  in
  {
    inner with
    local_path = None;
    bucket_functions = true;
    put =
      (fun ?mode key body ->
        inner.put ?mode key body;
        notify key);
  }

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-gc-verify-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let main = Local.create ~name:"main" (Filename.concat root "main") in
  let inner = Local.create ~name:"bucket" (Filename.concat root "bucket") in
  let function_on = Atomic.make false and at_once = Atomic.make false in
  let copy = bucket ~function_on ~at_once inner in
  Rt.run_sync (fun () ->
      let c =
        Composite.create
          ~timing:{ discard_poll = 0.2; probe_poll = 0.05; probe_wait = 0.5 }
          ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            {
              Composite.is_index = (fun _ -> false);
              is_journal = (fun _ -> false);
            }
          [
            { name = "main"; role = Main; store = main };
            { name = "bucket"; role = Backfill; store = copy };
          ]
      in
      let member =
        List.find
          (fun (m : Composite.member) -> m.name = "bucket")
          (Composite.members c)
      in
      let module C = struct
        let domain = d
        let store = Composite.store c
        let composite = c
        let versioning = true
        let chunk_size_config = None
        let max_downloads = 4
        let max_chunk_buffers = 4
      end in
      let module I = Integrity.Make (C) in
      List.iter
        (fun (body, stored) ->
          inner.put
            (Key.chunk d (Chunk_key.of_body body))
            (Bigstring.of_string stored))
        [("one", "one"); ("two", "two"); ("rot", "rotten")];
      let show label results =
        p "%s:\n" label;
        List.iter
          (fun (m, v) ->
            p "  %s: %s\n" m
              (match v with
                | Integrity.Unsupported -> "unsupported"
                | Done { corrupt } -> Printf.sprintf "done, %d corrupt" corrupt
                | Stalled { left; corrupt } ->
                    Printf.sprintf "stalled, %d left, %d corrupt" left corrupt
                | Abandoned { left; corrupt } ->
                    Printf.sprintf "abandoned, %d left, %d corrupt" left corrupt))
          results
      in
      let leftover () = List.length (inner.list_prefix (Key.verify_jobs d)) in
      let clear () =
        inner.delete_multi
          (List.map
             (fun (e : Store.entry) -> e.key)
             (inner.list_prefix (Key.verify_jobs d)))
      in
      let verify ?cancelled () =
        I.verify ?cancelled ~poll:0.05 ~stall_polls:3 ()
      in
      show "no confirmed function" (verify ());
      p "  requests written: %d\n" (leftover ());
      Atomic.set function_on true;
      p "probe: %b\n" (Composite.probe c member);
      show "function deployed" (verify ());
      p "  rotten chunk marked: %b, sound ones not: %b\n"
        (inner.head_opt (Key.marker d (Chunk_key.of_body "rot")) <> None)
        (inner.head_opt (Key.marker d (Chunk_key.of_body "one")) = None);
      Atomic.set function_on false;
      show "function no longer notified" (verify ());
      clear ();
      let after n =
        let checks = ref 0 in
        fun () ->
          incr checks;
          !checks > n
      in
      Atomic.set function_on true;
      Atomic.set at_once true;
      p
        "cancelled while queueing, the function consuming what was written: %s\n"
        (match verify ~cancelled:(after 3) () with
          | [_; (_, Abandoned _)] -> "cancelled"
          | [_; (_, Done _)] -> "done"
          | _ -> "other");
      Atomic.set function_on false;
      Atomic.set at_once false;
      clear ();
      show "cancelled while following" (verify ~cancelled:(after 66) ());
      p "  requests left for the function: %d\n" (leftover ()));
  Fs.rm_rf root
