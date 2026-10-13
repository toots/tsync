(* The cycle against a main that loses answers, refuses, blocks uploads and
   holds entries nobody projected (publication §8): what a client leaves after
   each, and what a restarted owner and its peers end with. *)

open Tsync_core
open Tsync_store
open Tsync_remote
open Tsync_sync

let p fmt = Printf.printf fmt

let base =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-cycle-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

(* What a client's link does to its requests. *)
type link = {
  mutable create : [ `Through | `Lost_answer | `Fails ];
  mutable chunks : [ `Through | `Blocked ];
  mutable chunk_puts : int;
  mutable before_create : unit -> unit;
  mutable before_chunk_read : unit -> unit;
  mutable down : bool;
}

let link () =
  {
    create = `Through;
    chunks = `Through;
    chunk_puts = 0;
    before_create = ignore;
    before_chunk_read = ignore;
    down = false;
  }

let faulty link (s : Store.t) : Store.t =
  let up () =
    if link.down then Fail.raise_ Fail.Link "the main does not answer"
  in
  {
    s with
    capabilities =
      (fun p ->
        up ();
        s.capabilities p);
    head_opt =
      (fun k ->
        up ();
        s.head_opt k);
    list_prefix =
      (fun ?max_keys p ->
        up ();
        s.list_prefix ?max_keys p);
    put_if_absent =
      (fun k b ->
        up ();
        if not (Key.is_log_entry k) then s.put_if_absent k b
        else (
          link.before_create ();
          match link.create with
            | `Through -> s.put_if_absent k b
            | `Fails -> Fail.raise_ Fail.Link "the request did not leave"
            | `Lost_answer ->
                ignore (s.put_if_absent k b);
                Fail.raise_ Fail.Link "the answer was lost"));
    put =
      (fun ?mode k b ->
        up ();
        if Key.chunk_of k <> None then (
          if link.chunks = `Blocked then
            Fail.raise_ Fail.Link "chunks do not pass";
          link.chunk_puts <- link.chunk_puts + 1);
        s.put ?mode k b);
    get_opt =
      (fun k ->
        up ();
        if Key.chunk_of k <> None then link.before_chunk_read ();
        s.get_opt k);
    get_range =
      (fun k off len ->
        up ();
        if Key.chunk_of k <> None then link.before_chunk_read ();
        s.get_range k off len);
    get_many =
      Option.map
        (fun get keys ->
          up ();
          if List.exists (fun k -> Key.chunk_of k <> None) keys then
            link.before_chunk_read ();
          get keys)
        s.get_many;
  }

let main root = Local.create ~name:"main" (Filename.concat root "store")

let client ?(link = link ()) ?replica ?(tuning = Tuning.default) ?stated
    ?(projects_all = false) ?(refused = ref false) ?(read_only = false)
    ?(lazy_tree = false) root name : (module Engine.S) =
  let data_dir = Filename.concat root (name ^ "/data") in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      ({
         Composite.name = "main";
         role = Main;
         store =
           (let s = faulty link (main root) in
            (* What an http-proxy main would state (05 §2.1). *)
            {
              s with
              capabilities =
                (fun p -> { (s.capabilities p) with domain_settings = stated });
            });
       }
      :: List.map
           (fun store -> { Composite.name = "replica"; role = Replica; store })
           (Option.to_list replica))
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = false
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat root (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = read_only
    let symlinks = `Keep
    let lazy_tree = lazy_tree
    let projects_all = projects_all

    (* 05 §2.1: a configuration its main contradicts is refused at each
       read of the settings in force. *)
    let settings _ =
      if !refused then
        Tsync_core.Fail.invalid "%s" "configured against what the main states";
      (tuning, symlinks)
  end in
  (module Engine.Make (C))

let started ?(background = false) ?link ?replica ?tuning ?stated ?projects_all
    ?refused ?read_only ?lazy_tree root name =
  let c =
    client ?link ?replica ?tuning ?stated ?projects_all ?refused ?read_only
      ?lazy_tree root name
  in
  let (module E) = c in
  E.start ~background ();
  c

let tree (module E : Engine.S) =
  let rec walk path =
    List.concat_map
      (fun (e : E.entry) ->
        let p = Names.join path e.name in
        if e.is_dir then (p ^ "/") :: walk p
        else (
          let h = E.open_read p in
          let content =
            Fun.protect
              ~finally:(fun () -> E.close_read h)
              (fun () -> Bigstring.to_string (E.read h ~off:0 ~len:1000))
          in
          [Printf.sprintf "%s=%S" p content]))
      (E.list_children path)
  in
  match walk "" with [] -> "(empty)" | l -> String.concat "  " l

let write (module E : Engine.S) path content =
  E.create path ~exclusive:false;
  E.write path ~off:0 (Bigstring.of_string content);
  E.close path

let uploaded (module E : Engine.S) =
  while E.pending_uploads () > 0 do
    Rt.sleep 0.02
  done

(* Uploads settle, then one cycle; a failure is the scenario's to show. *)
let settle (module E : Engine.S) =
  match E.drain ~grace:10. () with
    | () -> ()
    | exception e -> p "  drain failed: %s\n" (Printexc.to_string e)

let sync ?full (module E : Engine.S) =
  match E.resync ?full () with
    | r ->
        Printf.sprintf "%s, %d committed, %d pending"
          (match r.arrival with
            | `Entries n -> Printf.sprintf "%d entries merged" n
            | `State _ -> "arrived by state")
          r.committed r.pending
    | exception e -> "failed: " ^ Printexc.to_string e

let log root = Log_store.create d (main root)
let entries root = List.length (Log_store.read_entries (log root) 1)

let status (module E : Engine.S) =
  let a = E.activity () in
  Printf.sprintf "position %s, %d pending%s%s"
    (match a.position with Some n -> string_of_int n | None -> "none")
    a.pending
    (if a.pushing then ", a push in flight" else "")
    (match a.unfollowed with
      | Some (n, why) -> Printf.sprintf ", cannot follow entry %d (%s)" n why
      | None -> "")

let scenario name f =
  p "== %s\n" name;
  let root = Filename.concat base (string_of_int (Hashtbl.hash name)) in
  f root;
  p "\n"

let () =
  Fs.rm_rf base;
  Rt.run_sync (fun () ->
      scenario "a main that states a projector" (fun root ->
          let server = started root "S" in
          ignore (sync server);
          let projector =
            Tsync_checkout.Identity.client_uuid (Filename.concat root "S/data")
          in
          let a =
            started
              ~tuning:
                {
                  Tuning.default with
                  project_lease = 0.01;
                  project_quarantine = 0.02;
                  project_settle = 0.03;
                }
              ~stated:
                {
                  chunk = 4;
                  symlinks = `Keep;
                  lease = 30.;
                  quarantine = 300.;
                  settle = 600.;
                  entry_commands = 256;
                  projector = Some projector;
                }
              root "A"
          in
          ignore (sync a);
          write a "f" "abcd";
          uploaded a;
          p "  A: %s\n" (sync a);
          p "  the entry names the server as its projector: %b\n"
            (match Log_store.read_entry (log root) 1 with
              | Some { read = Entry e; _ } -> e.projector = Some projector
              | _ -> false);
          p "  A has not projected it: entries %d, the tree head %d\n"
            (entries root)
            (Log_store.tree_head (log root));
          Rt.sleep 0.1;
          ignore (sync a);
          Rt.sleep 0.1;
          ignore (sync a);
          p
            "  nor taken it over, long after its settle and quarantine: the \
             tree head %d\n"
            (Log_store.tree_head (log root));
          p "  S: %s\n" (sync server);
          p "  S has: the tree head %d\n" (Log_store.tree_head (log root)));
      scenario "a run of pushes projects each entry before the next"
        (fun root ->
          let link = link () in
          let a =
            started ~link
              ~tuning:{ Tuning.default with max_entry_commands = 2 }
              root "A"
          in
          let (module A) = a in
          ignore (sync a);
          let behind = ref [] in
          link.before_create <-
            (fun () ->
              behind :=
                (entries root - Log_store.tree_head (log root)) :: !behind;
              if List.length !behind = 2 then A.set_paused true);
          List.iter
            (fun n -> write a (Printf.sprintf "f%d" n) "abcd")
            [1; 2; 3; 4; 5; 6; 7];
          uploaded a;
          ignore (try sync a with _ -> "");
          p "  paused at the second push: %s; entries on the main: %d\n"
            (status a) (entries root);
          A.set_paused false;
          p "  resumed: %s\n" (sync a);
          p "  entries not projected when each was pushed: %s\n"
            (String.concat " " (List.rev_map string_of_int !behind));
          p "  entries on the main: %d, the tree head: %d\n" (entries root)
            (Log_store.tree_head (log root)));
      scenario "the answer to a create is lost; the owner restarts" (fun root ->
          let link = { (link ()) with create = `Lost_answer } in
          let a = started ~link root "A" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          p "  A after the failed push: %s; entries on the main: %d\n"
            (status a) (entries root);
          link.create <- `Through;
          let a = started ~link root "A" in
          write a "f" "two";
          uploaded a;
          p "  restarted, then a write to the same name: %s\n" (sync a);
          settle a;
          p "  A: %s; %s; entries: %d\n" (tree a) (status a) (entries root);
          let b = started root "B" in
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "a main that does not answer, from the start" (fun root ->
          let link = { (link ()) with down = true } in
          let a =
            match Rt.with_timeout 20. (fun () -> started ~link root "A") with
              | a -> a
              | exception e ->
                  p "  A does not start: %s\n" (Printexc.to_string e);
                  raise e
          in
          let (module A) = a in
          write a "f" "made offline";
          A.mkdir "dir" ~exclusive:false;
          p "  A, the main down: %s; %s\n" (tree a) (status a);
          p "  a cycle: %s\n"
            (try Rt.with_timeout 20. (fun () -> sync a)
             with _ -> "does not return");
          p "  A after it: %s\n" (status a);
          link.down <- false;
          ignore (A.rearm ());
          settle a;
          p "  the main back: %s\n" (status a);
          let b = started root "B" in
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "an entry whose answer was lost reaches the copies" (fun root ->
          let link = { (link ()) with create = `Lost_answer } in
          let replica =
            Local.create ~name:"replica" (Filename.concat root "r")
          in
          let a = started ~link ~replica root "A" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          link.create <- `Through;
          p "  A, the next cycle: %s\n" (sync a);
          settle a;
          let deadline = Rt.now () +. 10. in
          let copied () = replica.head_opt (Key.log_entry d 1) <> None in
          while (not (copied ())) && Rt.now () < deadline do
            Rt.sleep 0.02
          done;
          p "  the replica holds the entry: %b\n" (copied ()));
      scenario "a create that never left; the owner restarts" (fun root ->
          let link = { (link ()) with create = `Fails } in
          let a = started ~link root "A" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          p "  A after the failed push: %s; entries on the main: %d\n"
            (status a) (entries root);
          link.create <- `Through;
          let a = started ~link root "A" in
          p "  restarted: %s\n" (sync a);
          p "  A: %s; %s; entries: %d\n" (tree a) (status a) (entries root));
      scenario "an arrival record left by a crash is completed at start"
        (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "from A";
          settle a;
          let b = started root "B" in
          ignore (sync b);
          write a "f" "again";
          write a "g" "new";
          settle a;
          let state =
            Sync_state.open_ ~data_dir:(Filename.concat root "B/data") d
          in
          let theirs =
            List.concat_map
              (fun e -> Option.value ~default:[] (Log_store.commands e))
              (Log_store.read_entries (log root) 2)
          in
          Sync_state.set_arrival state
            {
              head = 2;
              view = None;
              steps =
                List.filter_map
                  (function
                    | `File (place, _, Some (Log_entry.Known m)) ->
                        Some (Sync_state.File (place, Some m))
                    | _ -> None)
                  theirs;
              before =
                List.map (fun c -> (Algebra.key_of c, Sync_state.Drop)) theirs;
            };
          let (module B) = b in
          let anchor = B.cursor () in
          let b = started root "B" in
          let (module B) = b in
          p "  B after its start, with no cycle: %s; %s\n" (tree b) (status b);
          p "  an anchor from before the crash: %s\n"
            (match B.changes_since anchor ~limit:10 with
              | `Stale -> "stale: the frontend lists again"
              | `Page _ -> "still answered");
          p "  the next cycle: %s\n" (sync b));
      scenario "a push refused by a commit that touches nothing pending"
        (fun root ->
          let link = link () in
          let a = started root "A" and b = started ~link root "B" in
          ignore (sync a);
          ignore (sync b);
          write b "mine" "from B";
          uploaded b;
          let sent = ref 0 in
          link.before_create <-
            (fun () ->
              link.before_create <- ignore;
              sent := link.chunk_puts;
              write a "theirs" "from A";
              settle a);
          p "  B: %s\n" (sync b);
          p "  chunks B sent after A's commit got ahead: %d; entries: %d\n"
            (link.chunk_puts - !sent) (entries root);
          p "  B: %s\n" (tree b);
          p "  A: %s\n"
            (ignore (sync a);
             tree a));
      scenario "more commands than an entry holds" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          let (module A) = a in
          for i = 1 to 600 do
            A.symlink (Printf.sprintf "l%03d" i) ~target:"t" ~exclusive:false
          done;
          p "  A: %s\n" (sync a);
          let sizes =
            List.map
              (fun e ->
                List.length (Option.value ~default:[] (Log_store.commands e)))
              (Log_store.read_entries (log root) 1)
          in
          p "  commands per entry: %s; tree head: %d\n"
            (String.concat ", " (List.map string_of_int sizes))
            (Log_store.tree_head (log root));
          let b = started root "B" in
          ignore (sync b);
          let (module B) = b in
          p "  B holds %d links\n" (List.length (B.list_children "")));
      scenario "a file renamed, then edited, while its upload is held"
        (fun root ->
          let link = link () in
          let a = started ~link root "A" and b = started root "B" in
          ignore (sync a);
          write a "f" "kept";
          settle a;
          link.chunks <- `Blocked;
          let (module A) = a in
          A.rename ~src:"f" ~dst:"g" ~exclusive:false;
          A.write "g" ~off:0 (Bigstring.of_string "EDIT");
          A.close "g";
          p "  A: %s\n" (sync a);
          p "  B meanwhile: %s\n"
            (ignore (sync b);
             tree b);
          link.chunks <- `Through;
          ignore (A.rearm ());
          settle a;
          p "  once the upload passes, A: %s\n" (status a);
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "an entry no client can decode, then voided" (fun root ->
          let a = started root "A" and b = started root "B" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          ignore (sync b);
          let path n =
            Filename.concat
              (Filename.concat root "store")
              (Key.to_string (Key.log_entry d n))
          in
          Fs.write_file_for_test (path 2) "not an entry";
          write a "g" "behind";
          uploaded a;
          p "  A: %s\n" (sync a);
          p "  A: %s\n" (status a);
          let synced = sync b in
          p "  B: %s; %s\n" synced (status b);
          ignore (Log_store.void_create (log root) 2 ~client:"operator");
          p "  voided. A: %s\n" (sync a);
          let synced = sync b in
          p "  B: %s; %s\n" synced (tree b);
          p "  entries: %d; tree head: %d\n" (entries root)
            (Log_store.tree_head (log root)));
      scenario "an entry of a later version" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          Fs.mkdir_p
            (Filename.dirname
               (Filename.concat
                  (Filename.concat root "store")
                  (Key.to_string (Key.log_entry d 1))));
          Fs.write_file_for_test
            (Filename.concat
               (Filename.concat root "store")
               (Key.to_string (Key.log_entry d 1)))
            {|{"v":2,"author":"x","commands":"new"}|};
          write a "f" "one";
          p "  A: %s\n" (sync a);
          p "  A: %s\n" (status a);
          ignore (Log_store.void_create (log root) 1 ~client:"operator");
          p "  a void object changes nothing for it: %s\n" (sync a));
      scenario "a chunk the main lost before the commit" (fun root ->
          let link = { (link ()) with create = `Fails } in
          let a = started ~link root "A" in
          ignore (sync a);
          write a "f" "abcdefgh";
          settle a;
          p "  A, its create failing: %s\n" (status a);
          ignore ((main root).delete (Key.chunk d (Chunk_key.of_body "efgh")));
          link.create <- `Through;
          p "  A, the chunk gone from the main: %s\n" (sync a);
          p "  A: %s\n" (status a);
          settle a;
          p "  after the upload ran again: %s; entries: %d\n" (status a)
            (entries root);
          let b = started root "B" in
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "a refused file is committed once written again" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "abcdefgh";
          settle a;
          let (module E) = a in
          (* Not in its cache either: the client holds these bytes nowhere. *)
          E.evict "f";
          E.rename ~src:"f" ~dst:"g" ~exclusive:true;
          ignore ((main root).delete (Key.chunk d (Chunk_key.of_body "efgh")));
          p "  A, renamed, a chunk gone from the main: %s\n" (sync a);
          p "  damaged: %s\n" (String.concat " " (E.activity ()).damaged);
          write a "g" "ijkl";
          settle a;
          p "  A, g written again: %s; damaged: %d\n" (status a)
            (List.length (E.activity ()).damaged);
          let b = started root "B" in
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "a chunk the main lost, which the cache still holds" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "abcdefgh";
          settle a;
          let (module E) = a in
          E.rename ~src:"f" ~dst:"g" ~exclusive:true;
          ignore ((main root).delete (Key.chunk d (Chunk_key.of_body "efgh")));
          p "  A, renamed, a chunk gone from the main: %s\n" (sync a);
          p "  damaged: %d; the main holds the chunk again: %b\n"
            (List.length (E.activity ()).damaged)
            ((main root).head_opt (Key.chunk d (Chunk_key.of_body "efgh"))
            <> None));
      scenario "an edit that inherits a chunk the main lost" (fun root ->
          let link = link () in
          let a = started root "A" and b = started ~link root "B" in
          let (module B) = b in
          ignore (sync a);
          write a "f" "abcdefghijkl";
          settle a;
          ignore (sync b);
          (* B never read the file: it holds only the group it writes into. *)
          link.create <- `Fails;
          B.write "f" ~off:9 (Bigstring.of_string "Z");
          B.close "f";
          settle b;
          ignore ((main root).delete (Key.chunk d (Chunk_key.of_body "abcd")));
          link.create <- `Through;
          p "  B, an inherited chunk gone from the main: %s\n" (sync b);
          p "  damaged: %s\n" (String.concat " " (B.activity ()).damaged);
          p "  B, a cycle later: %s\n" (sync b));
      scenario "a parked copy is retried, and the pause flag is where 07 says"
        (fun root ->
          let refusing = ref true in
          let inner = Local.create ~name:"replica" (Filename.concat root "r") in
          let replica =
            {
              inner with
              put =
                (fun ?mode k b ->
                  if !refusing then Fail.raise_ Fail.Corrupt "the copy refuses";
                  inner.put ?mode k b);
            }
          in
          let a = started ~replica root "A" in
          let (module A) = a in
          ignore (sync a);
          write a "f" "abcd";
          settle a;
          let copied () =
            inner.head_opt (Key.chunk d (Chunk_key.of_body "abcd")) <> None
          in
          p "  the replica refusing, it holds the chunk: %b\n" (copied ());
          refusing := false;
          let rearmed = A.rearm () in
          settle a;
          (* The re-armed jobs run in no order, and a settle ends at the first
             that fails: the entry's, when it runs before its chunk's. *)
          let deadline = Rt.now () +. 10. in
          while (not (copied ())) && Rt.now () < deadline do
            Rt.sleep 0.02
          done;
          p "  re-armed: %b; the replica holds the chunk: %b\n" (rearmed > 0)
            (copied ());
          A.set_paused true;
          p "  paused, the flag exists: %b\n"
            (Fs.exists
               (List.fold_left Filename.concat root
                  ["A"; "data"; "paused"; Domain_name.to_string d]));
          A.set_paused false);
      scenario "an entry its author never projected" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          let module C = struct
            let domain = d
            let store = main root

            let composite =
              Composite.create ~domain:d
                ~data_dir:(Filename.concat root "dead")
                ~owner:true ~poke:ignore ~knowledge
                [{ name = "main"; role = Main; store = main root }]

            let versioning = false
            let chunk_size_config = Some 4
            let max_downloads = 4
            let max_chunk_buffers = 4
          end in
          let module R = Remote.Make (C) in
          let m =
            R.upload_chunks ~name:"g" ~size:4 ~chunk_size:4 ~mtime:1. (fun _ ->
                Bytes (Bigstring.of_string "dead"))
          in
          ignore
            (Log_store.create_entry (log root) 2
               (Log_entry.encode
                  {
                    author = "a client that stopped";
                    projector = None;
                    commands =
                      [
                        `File
                          ( { parent = Folder_id.root; name = "g" },
                            None,
                            Some (Known m) );
                      ];
                  }));
          p "  A merges it without waiting for its projection: %s\n" (sync a);
          p "  A: %s; tree head: %d of 2\n" (tree a)
            (Log_store.tree_head (log root));
          let serving = started ~projects_all:true root "S" in
          let synced = sync serving in
          p
            "  an owner whose listener projects, at its first cycle: %s; tree \
             head: %d of 2\n"
            synced
            (Log_store.tree_head (log root));
          write a "h" "after";
          uploaded a;
          let synced = sync a in
          p "  A commits behind it: %s; tree head: %d of %d\n" synced
            (Log_store.tree_head (log root))
            (entries root);
          let b = started root "B" in
          p "  a new client arrives by state over the unprojected entries: %s\n"
            (ignore (sync b);
             tree b));
      scenario "a position that is gone: arrival by state keeps pending work"
        (fun root ->
          let a = started root "A" and b = started root "B" in
          ignore (sync a);
          ignore (sync b);
          write a "f" "from A";
          write a "shared" "from A";
          settle a;
          write b "mine" "from B";
          write b "shared" "from B";
          uploaded b;
          Fs.unlink_quiet (Filename.concat root "B/data/sync/docs/position");
          p "  B: %s\n" (sync b);
          p "  B: %s\n" (tree b);
          p "  A: %s\n"
            (ignore (sync a);
             tree a));
      scenario "a file written again with the bytes it had" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "abcd";
          settle a;
          write a "f" "abcd";
          uploaded a;
          p "  A, once the upload ended: %s\n" (status a));
      scenario "a write that waits for its base while another file arrives"
        (fun root ->
          let link = link () in
          let a = started root "A" and b = started ~link root "B" in
          let (module B) = b in
          ignore (sync a);
          write a "f" "abcdefgh";
          settle a;
          ignore (sync b);
          write a "other" "x";
          settle a;
          let reading = Rt.Promise.create () and go_on = Rt.Promise.create () in
          link.before_chunk_read <-
            (fun () ->
              link.before_chunk_read <- ignore;
              Rt.Promise.resolve reading ();
              Rt.Promise.await go_on);
          let written =
            Rt.async (fun () ->
                B.write "f" ~off:1 (Bigstring.of_string "Z");
                B.close "f")
          in
          Rt.with_timeout 10. (fun () -> Rt.Promise.await reading);
          (* An arrival that waited for the key of this write would never
             return: the write goes on only after it. *)
          p "  B, its write waiting: %s\n"
            (try Rt.with_timeout 20. (fun () -> sync b)
             with _ -> "the arrival waits for the write");
          Rt.Promise.resolve go_on ();
          Rt.Promise.await written;
          uploaded b;
          p "  B, the write made: %s\n" (status b);
          p "  B: %s\n" (sync b);
          p "  A: %s\n"
            (ignore (sync a);
             tree a));
      scenario "an uploaded edit whose before-value is lost" (fun root ->
          let a = started root "A" in
          ignore (sync a);
          write a "f" "abcd";
          settle a;
          write a "f" "WXYZ";
          uploaded a;
          Fs.rm_rf (Filename.concat root "A/data/sync/docs/before");
          let a = started root "A" in
          p "  A restarted: %s\n" (status a);
          p "  A: %s\n" (sync a);
          let b = started root "B" in
          p "  B: %s\n"
            (ignore (sync b);
             tree b));
      scenario "a write that fails leaves nothing pending" (fun root ->
          let a = started root "A" in
          let (module A) = a in
          ignore (sync a);
          A.mkdir "dir" ~exclusive:false;
          ignore (sync a);
          p "  a write to a folder: %s\n"
            (match A.write "dir" ~off:0 (Bigstring.of_string "x") with
              | () -> "accepted"
              | exception Fail.E f -> "refused: " ^ f.reason);
          p "  A: %s\n" (status a));
      scenario "the same bytes written on two machines" (fun root ->
          let a = started root "A" and b = started root "B" in
          ignore (sync a);
          ignore (sync b);
          let mtime (module E : Engine.S) =
            match
              List.find_opt
                (fun (e : E.entry) -> e.name = "f")
                (E.list_children "")
            with
              | Some e -> e.st.mtime
              | None -> nan
          in
          write a "f" "abcd";
          Rt.sleep 0.05;
          write b "f" "abcd";
          uploaded b;
          settle a;
          let synced = sync b in
          p "  B: %s; %s\n" synced (tree b);
          p "  B has the file as the main holds it: %b\n" (mtime a = mtime b);
          p "  entries: %d\n" (entries root));
      scenario "a read-only client leaves an entry to those that write"
        (fun root ->
          let quick =
            {
              Tuning.default with
              project_lease = 0.01;
              project_quarantine = 0.02;
              project_settle = 0.03;
            }
          in
          let a =
            started
              ~stated:
                {
                  chunk = 4;
                  symlinks = `Keep;
                  lease = 30.;
                  quarantine = 300.;
                  settle = 600.;
                  entry_commands = 256;
                  projector = Some (String.make 32 'f');
                }
              root "A"
          in
          ignore (sync a);
          write a "f" "abcd";
          uploaded a;
          ignore (sync a);
          let cycles c =
            for _ = 1 to 4 do
              ignore (sync c);
              Rt.sleep 0.05
            done
          in
          let b = started ~tuning:quick ~read_only:true root "B" in
          cycles b;
          p "  read-only B: %s; the tree head %d, takeovers %d\n" (tree b)
            (Log_store.tree_head (log root))
            (fst (Log_store.takeover (log root) 1));
          let c = started ~tuning:quick root "C" in
          cycles c;
          p "  C, which writes: the tree head %d, takeovers %d\n"
            (Log_store.tree_head (log root))
            (fst (Log_store.takeover (log root) 1)));
      (* From here on the cycles run in the background, until the process
         stops. *)
      scenario "a poll leaves a change to its batch delay" (fun root ->
          let a = started ~background:true root "A" in
          let (module A) = a in
          ignore (sync a);
          write a "f" "abcd";
          uploaded a;
          A.poll ();
          Rt.sleep 1.;
          p "  A, a second after a poll: %s\n" (status a);
          p "  A, asked to sync: %s\n" (sync a));
      scenario "a configuration the main refuses, then set right" (fun root ->
          let refused = ref false in
          let a =
            started ~background:true ~refused
              ~tuning:{ Tuning.default with batch_delay = 0.05 }
              root "A"
          in
          let (module A) = a in
          ignore (sync a);
          refused := true;
          write a "f" "abcd";
          let until what f =
            let deadline = Rt.now () +. 20. in
            while (not (f ())) && Rt.now () < deadline do
              Rt.sleep 0.05
            done;
            if not (f ()) then p "  never: %s\n" what
          in
          until "the cycle reports it" (fun () ->
              (A.activity ()).failing <> None);
          p "  A: %s; failing: %s\n" (status a)
            (Option.value ~default:"no" (A.activity ()).failing);
          (* Past the retry floor, so the loop has computed a wait again. *)
          Rt.sleep (2. *. Cycle.retry_floor);
          refused := false;
          until "the change is committed" (fun () ->
              (A.activity ()).pending = 0);
          until "the failure is cleared" (fun () ->
              (A.activity ()).failing = None);
          p "  set right: %s; failing: %s\n" (status a)
            (Option.value ~default:"no" (A.activity ()).failing));
      scenario "a paused client leaves another's entry to its projector"
        (fun root ->
          let quick =
            {
              Tuning.default with
              project_lease = 0.01;
              project_quarantine = 0.02;
              project_settle = 0.03;
            }
          in
          let a =
            started
              ~stated:
                {
                  chunk = 4;
                  symlinks = `Keep;
                  lease = 30.;
                  quarantine = 300.;
                  settle = 600.;
                  entry_commands = 256;
                  projector = Some (String.make 32 'f');
                }
              root "A"
          in
          ignore (sync a);
          write a "f" "abcd";
          uploaded a;
          ignore (sync a);
          (* Paused before its cycle starts: a first cycle would watch the
             entry and take it over. *)
          let flag =
            Engine.pause_flag ~data_dir:(Filename.concat root "B/data") d
          in
          Fs.mkdir_p (Filename.dirname flag);
          Fs.write_file_for_test flag "";
          let b = started ~background:true ~tuning:quick root "B" in
          let (module B) = b in
          Rt.sleep 3.5;
          p "  B paused: the tree head %d of %d, takeovers %d\n"
            (Log_store.tree_head (log root))
            (entries root)
            (fst (Log_store.takeover (log root) 1));
          B.set_paused false;
          let deadline = Rt.now () +. 20. in
          while Log_store.tree_head (log root) < 1 && Rt.now () < deadline do
            ignore (sync b);
            Rt.sleep 0.05
          done;
          p "  B resumed: the tree head %d of %d, takeovers %d\n"
            (Log_store.tree_head (log root))
            (entries root)
            (fst (Log_store.takeover (log root) 1)));
      scenario "two files swapped, over the bytes of one entry" (fun root ->
          let tuning = { Tuning.default with max_entry_bytes = 1000 } in
          let a = started ~tuning root "A" and b = started root "B" in
          ignore (sync a);
          let repeated c = String.make 40 c in
          write a "x" (repeated 'a');
          write a "y" (repeated 'b');
          settle a;
          ignore (sync a);
          let before = entries root in
          let (module A) = a in
          A.rename ~src:"x" ~dst:"t" ~exclusive:true;
          A.rename ~src:"y" ~dst:"x" ~exclusive:true;
          A.rename ~src:"t" ~dst:"y" ~exclusive:true;
          p "  A: %s\n" (sync a);
          let size n =
            (Unix.stat
               (Filename.concat
                  (Filename.concat root "store")
                  (Key.to_string (Key.log_entry d n))))
              .st_size
          in
          p "  the swap made %d entry, over the limit: %b\n"
            (entries root - before)
            (size (entries root) > tuning.max_entry_bytes);
          ignore (sync b);
          let (module B) = b in
          let first path =
            let h = B.open_read path in
            Fun.protect
              ~finally:(fun () -> B.close_read h)
              (fun () -> Bigstring.to_string (B.read h ~off:0 ~len:4))
          in
          p "  B: x=%S… y=%S…\n" (first "x") (first "y"));
      scenario "a lazy tree restarted with a create whose answer was lost"
        (fun root ->
          let link = { (link ()) with create = `Lost_answer } in
          let a = started ~lazy_tree:true ~link root "A" in
          ignore (sync a);
          write a "f" "one";
          settle a;
          p "  A after the failed push: %s\n" (status a);
          link.create <- `Through;
          let a = started ~background:true ~lazy_tree:true ~link root "A" in
          let (module A) = a in
          let deadline = Rt.now () +. 10. in
          while (A.activity ()).pushing && Rt.now () < deadline do
            Rt.sleep 0.05
          done;
          p "  restarted and asked nothing: %s\n" (status a));
      Stop.request ());
  Test_support.finish base
