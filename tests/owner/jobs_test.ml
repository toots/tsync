(* The exit status and last word of owner jobs whose result is not a success
   (spec 07 §5.4): a probe that confirmed nothing, a repair cut short. *)

open Tsync_core
open Tsync_store
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let root = Printf.sprintf "/tmp/tsync-jobs-%d" (Unix.getpid ())

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" (Filename.concat root "home");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"d","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let d = Domain_name.v "d"

(* A bucket whose function, when deployed, consumes each request. *)
let bucket ~function_on (inner : Store.t) =
  {
    inner with
    local_path = None;
    bucket_functions = true;
    put =
      (fun ?mode key body ->
        inner.put ?mode key body;
        if Atomic.get function_on && Key.parse_discard_job key <> None then
          Rt.spawn ~name:"bucket function" (fun () -> ignore (inner.delete key)));
  }

let () =
  Rt.run_sync (fun () ->
      let dom =
        Tsync_domain.Domain.build ~owner:true config (List.hd config.domains)
      in
      let engine = Tsync_domain.Domain.engine dom in
      let run ?(cancelled = Fun.const false) ?(narrate = Narrate.none) dom job =
        let io = { Jobs.out = p "  %s"; narrate; cancelled } in
        p "  exit %d" (Jobs.run io dom engine job)
      in
      p "== gc --probe";
      let function_on = Atomic.make false in
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let copy =
        bucket ~function_on
          (Local.create ~name:"bucket" (Filename.concat root "bucket"))
      in
      let with_bucket =
        {
          dom with
          composite =
            Composite.create
              ~timing:
                { discard_poll = 0.2; probe_poll = 0.05; probe_wait = 0.5 }
              ~domain:d
              ~data_dir:(Filename.concat root "bucket-data")
              ~owner:true ~poke:ignore
              ~knowledge:
                {
                  Composite.is_index = (fun _ -> false);
                  is_journal = (fun _ -> false);
                }
              [
                { name = "main"; role = Main; store = main };
                { name = "bucket"; role = Backfill; store = copy };
              ];
        }
      in
      p "no function deployed:";
      run with_bucket (Gc_copies Probe);
      Atomic.set function_on true;
      p "the function deployed:";
      run with_bucket (Gc_copies Probe);
      p "no store with a bucket function:";
      run dom (Gc_copies Probe);
      p "== gc says when a request waits on a copy";
      let junk = Key.chunk d (Chunk_key.of_body "junk") in
      main.put junk (Bigstring.of_string "junk");
      copy.put junk (Bigstring.of_string "junk");
      let live = Chunk_key.of_body "live" in
      main.put (Key.chunk d live) (Bigstring.of_string "live");
      main.put
        (Key.child d Folder_id.root "kept.txt")
        (Bigstring.of_string
           (Manifest.make ~name:"kept.txt" ~size:Chunking.chunk_size_min
              ~mtime:0. ~chunk_size:Chunking.chunk_size_min [live])
             .body);
      Atomic.set function_on false;
      Composite.start with_bucket.composite;
      let said = ref [] in
      let quiet job =
        let io =
          {
            Jobs.out = (fun l -> said := l :: !said);
            narrate = Narrate.none;
            cancelled = Fun.const false;
          }
        in
        ignore (Jobs.run io with_bucket engine job)
      in
      quiet (Gc { apply = true; verify = false; abort = false; budget = None });
      Composite.settle ~timeout:10. with_bucket.composite;
      said := [];
      quiet (Gc { apply = false; verify = false; abort = false; budget = None });
      p "a later dry run, the function not notified: %s"
        (match List.filter (fun l -> Text.contains l "outstanding") !said with
          | [] -> "says nothing of the request"
          | l ->
              (* Its age varies. *)
              String.concat "; "
                (List.map (fun l -> List.hd (String.split_on_char ',' l)) l));
      p "== status: corruption markers";
      let corrupted () =
        let report = Report.create dom engine ~frontend:(fun () -> None) in
        String.concat ", "
          (List.map
             (fun (b : Tsync_status.Status_report.backend) ->
               match b.corrupted with
                 | Not_checked _ -> "not checked"
                 | Checked { chunks; truncated } ->
                     Printf.sprintf "%d corrupt%s" chunks
                       (if truncated then " or more" else ""))
             (Report.domain_body report).backends)
      in
      p "a store that verifies its writes, no marker: %s" (corrupted ());
      main.put
        (Key.marker d (Chunk_key.of_body "rot"))
        (Bigstring.of_string "{}");
      p "with a marker: %s" (corrupted ());
      ignore (main.delete (Key.marker d (Chunk_key.of_body "rot")));
      p "== data-integrity --repair";
      let live = Folder_id.v "0000000000a1-1" in
      let put key body = main.put key (Bigstring.of_string body) in
      put
        (Key.child d Folder_id.root "live")
        (Folder.marker_body { name = "live"; id = live });
      put (Key.anchor d live)
        (Folder.anchor_body { parent = Folder_id.root; aname = "live" });
      List.iter
        (fun e ->
          put (Key.trash_entry d e)
            (Folder.trash_body { name = "live"; id = live } ~path:"live"))
        ["e1"; "e2"];
      let repair =
        Jobs.Integrity
          {
            verify = false;
            repair = true;
            apply = false;
            detail = false;
            source = None;
          }
      in
      p "two findings, a dry run:";
      run dom repair;
      (* Cancelled once the first repair has been narrated. *)
      let stop = Atomic.make false in
      let narrate =
        {
          Narrate.none with
          say =
            (fun s ->
              if Text.contains s "would be deleted" then Atomic.set stop true);
        }
      in
      p "cancelled after the first:";
      run ~cancelled:(fun () -> Atomic.get stop) ~narrate dom repair);
  Fs.rm_rf root
