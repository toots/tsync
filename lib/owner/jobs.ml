open Tsync_core
open Tsync_gc

type copies = Probe | Outstanding | Retry_outstanding [@@deriving yojson]

type t =
  | Sync of { full : bool }
  | Gc of { apply : bool; verify : bool; abort : bool; budget : float option }
  | Gc_copies of copies
  | Expire of { apply : bool; cutoff : float }
  | Purge of { apply : bool; path : string }
  | Import of {
      src : string;
      only : string list;
      exclude : string list;
      force_rehash : bool;
    }
  | Rsync of {
      src : string;
      src_in_domain : bool;
      dst : string;
      dst_in_domain : bool;
      move : bool;
      dry_run : bool;
    }
  | Mirror of {
      source : string option;
      skip_chunks : bool;
      path : string option;
    }
  | Integrity of {
      verify : bool;
      repair : bool;
      apply : bool;
      detail : bool;
      source : string option;
    }
[@@deriving yojson]

let kind = function
  | Sync { full = true } -> "sync --full"
  | Sync _ -> "sync"
  | Gc { abort = true; _ } -> "gc --abort"
  | Gc { apply = true; _ } -> "gc --apply"
  | Gc _ -> "gc"
  | Gc_copies Probe -> "gc --probe"
  | Gc_copies Outstanding -> "gc --outstanding"
  | Gc_copies Retry_outstanding -> "gc --retry-outstanding"
  | Expire _ -> "expire"
  | Purge _ -> "trash --purge"
  | Import _ -> "import"
  | Mirror _ -> "mirror"
  | Rsync { move = true; _ } -> "rsync --move"
  | Rsync _ -> "rsync"
  | Integrity { verify = true; _ } -> "data-integrity --verify"
  | Integrity { repair = true; _ } -> "data-integrity --repair"
  | Integrity _ -> "data-integrity"

type io = {
  out : string -> unit;
  narrate : Narrate.t;
  cancelled : unit -> bool;
}

let dry_note apply =
  if apply then "" else " (dry run: nothing changed; --apply to act)"

let outcome = function
  | Collector.Completed -> "completed"
  | Suspended { phase; cursor } ->
      Printf.sprintf "left open in %s after %S"
        (Gc_record.phase_name phase)
        cursor
  | Halted reason -> "stopped, left open: " ^ reason

let print_survey out (s : Collector.survey) =
  let say fmt = Printf.ksprintf out fmt in
  say "%s: %d chunks referenced, %d reclaimable (%s)%s" s.surveyed
    s.chunks_referenced s.chunks_reclaimable
    (Narrate.size s.bytes_reclaimable)
    (dry_note false);
  Option.iter
    (fun (phase, cursor) ->
      say "  a run is open: %s after %S" (Gc_record.phase_name phase) cursor)
    s.run;
  if s.run_unreadable then say "  a run record is present but unreadable";
  List.iter
    (fun (copy, n) -> say "  %s would be told %d deletions" copy n)
    s.per_copy;
  if s.chunks_missing <> [] then (
    say "  %d referenced chunks are missing from %s:"
      (List.length s.chunks_missing)
      s.surveyed;
    List.iter
      (fun c -> say "    %s" (Chunk_key.to_string c))
      (List.filteri (fun i _ -> i < 20) s.chunks_missing));
  if s.chunks_corrupt > 0 then
    say "  %d referenced chunks misread" s.chunks_corrupt

let print_stats out (s : Collector.stats) =
  let say fmt = Printf.ksprintf out fmt in
  say "%s: %s; %d namespaces marked, %d chunks promoted, %d reclaimed (%s)"
    s.main (outcome s.outcome) s.roots_marked s.chunks_promoted
    s.chunks_reclaimed
    (Narrate.size s.bytes_reclaimed);
  if s.chunks_verified > 0 then
    say "  verified %d: %d corrupt, %d unreadable, %d markers cleared"
      s.chunks_verified s.chunks_corrupt s.chunks_unreadable s.chunks_cleared

let refuse = function
  | Collector.Busy ->
      Fail.raise_ Fail.Load "another collection holds this domain's run lock"
  | Unsupported reason -> Fail.raise_ Fail.Refused "cannot collect: %s" reason

let gc io c ~apply ~verify ~abort ~budget =
  let say fmt = Printf.ksprintf io.out fmt in
  if apply || abort then (
    match
      Collector.run ?budget ~narrate:io.narrate ~verify ~keep:abort
        ~cancelled:io.cancelled c
    with
      | Error f -> refuse f
      | Ok stats ->
          List.iter (print_stats io.out) stats;
          if
            List.for_all
              (fun (s : Collector.stats) -> s.outcome = Completed)
              stats
          then 0
          else 1)
  else (
    match
      Collector.dry_run ~narrate:io.narrate ~verify ~cancelled:io.cancelled c
    with
      | Error f -> refuse f
      | Ok surveys ->
          List.iter
            (function
              | Ok s -> print_survey io.out s
              | Error reason -> say "survey stopped: %s" reason)
            surveys;
          if List.for_all Result.is_ok surveys then 0 else 1)

(* The copies' side of a collection (gc §5.7): the bucket function, and the
   discard requests it has not consumed. *)
let copies io c act =
  let say fmt = Printf.ksprintf io.out fmt in
  match act with
    | Probe ->
        let stores =
          List.filter
            (fun (m : Tsync_store.Composite.member) ->
              m.role <> Read_only && m.store.bucket_functions)
            (Tsync_store.Composite.members c)
        in
        if stores = [] then
          say "no store of this domain can run a bucket function";
        List.iter
          (fun (m : Tsync_store.Composite.member) ->
            say "%s: probing its bucket function (up to 3 minutes)" m.name;
            say "  %s"
              (if Tsync_store.Composite.probe ~cancelled:io.cancelled c m then
                 "confirmed"
               else "not confirmed: requests were not consumed"))
          stores;
        0
    | Outstanding ->
        (match Tsync_store.Composite.outstanding c with
          | [] -> say "no discard request outstanding"
          | l ->
              List.iter
                (fun (o : Tsync_store.Composite.outstanding) ->
                  say "%s: %s, %d keys, %.0f min old" o.copy
                    (Key.to_string o.request) o.keys (o.age /. 60.))
                l);
        0
    | Retry_outstanding ->
        say "%d discard requests re-delivered"
          (Tsync_store.Composite.retry_outstanding c);
        0

let expire io dom ~apply ~cutoff =
  let say fmt = Printf.ksprintf io.out fmt in
  let module R = Retention.Make ((val Tsync_domain.Domain.context dom)) in
  let r =
    R.expire ~narrate:io.narrate ~apply ~cancelled:io.cancelled ~cutoff ()
  in
  say "trash %d, versions %d, journal entries %d, shares %d%s%s"
    r.counts.trash_deleted r.counts.versions_deleted r.counts.journal_deleted
    r.counts.shares_deleted (dry_note apply)
    (if r.cancelled then "; cancelled before the end" else "");
  List.iter
    (fun (id, reason) ->
      say "  purge of %s stopped: %s" (Folder_id.to_string id) reason)
    r.stopped;
  List.iter
    (fun k -> say "  unparseable share left: %s" (Key.to_string k))
    r.unparseable_shares;
  if r.stopped = [] && not r.cancelled then 0 else 1

let purge io dom ~apply ~path =
  let say fmt = Printf.ksprintf io.out fmt in
  let module R = Retention.Make ((val Tsync_domain.Domain.context dom)) in
  match R.purge ~narrate:io.narrate ~apply ~cancelled:io.cancelled path with
    | Purged n ->
        say "%s: %d objects purged%s" path n (dry_note apply);
        0
    | Not_in_trash ->
        say "%s is not in the trash" path;
        1
    | Live_elsewhere ->
        say "%s is live elsewhere; not purged" path;
        1
    | Stopped reason ->
        say "%s: purge stopped, the rest stays in the trash: %s" path reason;
        1

let kind_name = function
  | Integrity.Twice _ -> "folders at two paths"
  | Disowned _ -> "disowned markers"
  | Trashed_live _ -> "trash entries of live folders"
  | Unanchored _ -> "folders without an anchor"
  | Orphan _ -> "unreachable folders"

let counted names =
  let tally = Hashtbl.create 8 in
  List.iter
    (fun n ->
      Hashtbl.replace tally n
        (1 + Option.value ~default:0 (Hashtbl.find_opt tally n)))
    names;
  List.sort compare (Hashtbl.fold (fun n k acc -> (n, k) :: acc) tally [])

let unfixed = function
  | Integrity.Left | Young | Nested | Incomplete | Failed _ -> true
  | Deleted | Anchored | Adopted -> false

let verify io (dom : Tsync_domain.Domain.t) =
  let say fmt = Printf.ksprintf io.out fmt in
  let module I = Integrity.Make ((val Tsync_domain.Domain.context dom)) in
  let results = I.verify ~narrate:io.narrate ~cancelled:io.cancelled () in
  let followed =
    List.filter (fun (_, v) -> v <> Integrity.Unsupported) results
  in
  if followed = [] then (
    say "nothing queued: no member has a confirmed bucket function (gc --probe)";
    1)
  else (
    List.iter
      (fun (member, v) ->
        match v with
          | Integrity.Unsupported -> ()
          | Done { corrupt = 0 } -> say "%s: verified, no corrupt chunk" member
          | Done { corrupt } ->
              say "%s: verified, %d corrupt chunks (data-integrity --repair)"
                member corrupt
          | Stalled { left; corrupt } ->
              say
                "%s: stalled with %d shard requests left and %d corrupt chunks \
                 so far: is its bucket function deployed and notified?"
                member left corrupt
          | Abandoned { left; corrupt } ->
              say
                "%s: cancelled with %d shard requests left and %d corrupt \
                 chunks so far; its function still consumes them"
                member left corrupt)
      followed;
    if List.for_all (fun (_, v) -> v = Integrity.Done { corrupt = 0 }) followed
    then 0
    else 1)

let integrity io (dom : Tsync_domain.Domain.t) ~repair ~apply ~detail ~source =
  let say fmt = Printf.ksprintf io.out fmt in
  if repair && apply && dom.domain.read_only then
    Fail.raise_ Fail.Read_only "%s is read-only"
      (Domain_name.to_string dom.name);
  let module I = Integrity.Make ((val Tsync_domain.Domain.context dom)) in
  let r = I.report ~narrate:io.narrate ~cancelled:io.cancelled () in
  if not repair then (
    if Integrity.healthy r then
      say "%s: healthy (%d tombstones)"
        (Domain_name.to_string dom.name)
        r.tombstones
    else (
      List.iter
        (fun (n, k) -> say "%d %s" k n)
        (counted (List.map kind_name r.findings));
      if r.corrupt <> [] then say "%d corrupt chunks" (List.length r.corrupt);
      if r.unreadable <> [] then
        say "%d folders could not be read: the walk is incomplete"
          (List.length r.unreadable);
      if detail then (
        List.iter (fun f -> say "  %s" (Integrity.describe f)) r.findings;
        List.iter
          (fun (c : Integrity.corrupt) ->
            say "  %s marked corrupt on %s"
              (Chunk_key.to_string c.chunk)
              c.member)
          r.corrupt));
    if Integrity.healthy r then 0 else 1)
  else (
    let tree =
      I.repair_tree ~narrate:io.narrate ~apply ~cancelled:io.cancelled r
    in
    let chunks =
      I.repair_chunks ~narrate:io.narrate ~apply ?source ~cancelled:io.cancelled
        r
    in
    let acted verb = if apply then verb else "would be " ^ verb in
    let outcome = function
      | Integrity.Deleted -> acted "deleted"
      | Anchored -> acted "anchored"
      | Adopted -> acted "adopted into the trash"
      | Young -> "left: younger than the grace"
      | Nested -> "left: inside an unreachable folder"
      | Left -> "left: resolve by hand"
      | Incomplete -> "left: the walk could not read every folder"
      | Failed _ -> "failed"
    and chunk_outcome = function
      | Integrity.Cleared -> acted "rewritten from their own copy"
      | Repaired _ -> acted "repaired from another member"
      | Unrepairable -> "unrepairable"
    in
    List.iter
      (fun (n, k) -> say "%d %s" k n)
      (counted
         (List.map (fun (_, o) -> outcome o) tree
         @ List.map (fun (_, o) -> "chunks " ^ chunk_outcome o) chunks));
    if detail then (
      List.iter
        (fun (f, o) ->
          say "  %s: %s%s" (Integrity.describe f) (outcome o)
            (match o with Failed reason -> " (" ^ reason ^ ")" | _ -> ""))
        tree;
      List.iter
        (fun ((c : Integrity.corrupt), o) ->
          say "  %s on %s: %s%s"
            (Chunk_key.to_string c.chunk)
            c.member (chunk_outcome o)
            (match o with Repaired from -> " (" ^ from ^ ")" | _ -> ""))
        chunks);
    if tree = [] && chunks = [] then
      say "%s: nothing to repair" (Domain_name.to_string dom.name);
    if not apply then say "(dry run: nothing changed; drop --dry-run to act)";
    if
      List.exists (fun (_, o) -> unfixed o) tree
      || List.exists (fun (_, o) -> o = Integrity.Unrepairable) chunks
    then 1
    else 0)

let import io (module E : Tsync_sync.Engine.S) ~src ~only ~exclude ~force_rehash
    =
  let say fmt = Printf.ksprintf io.out fmt in
  let r =
    E.import ~narrate:io.narrate ~cancelled:io.cancelled ~only ~exclude
      ~force_rehash src
  in
  say
    "imported %s (%s); %d already in the domain, %d links skipped, %d failed%s"
    (Narrate.count r.imported "file")
    (Narrate.size r.bytes) r.skipped r.skipped_symlinks (List.length r.failed)
    (if r.cancelled then "; cancelled before the end" else "");
  List.iter (fun (path, reason) -> say "  %s: %s" path reason) r.failed;
  if r.failed = [] && not r.cancelled then 0 else 1

let rsync io (module E : Tsync_sync.Engine.S) ~src ~dst ~move ~dry_run =
  let say fmt = Printf.ksprintf io.out fmt in
  let r =
    E.rsync ~narrate:io.narrate ~cancelled:io.cancelled ~move ~dry_run ~src ~dst
      ()
  in
  if dry_run then
    List.iter
      (fun (rel, d) ->
        say "%s: %s"
          (if rel = "" then "." else rel)
          (Tsync_sync.Rsync_plan.describe d))
      r.planned
  else (
    say
      "copied %d (%s moved), %d identical, %d folders, %d skipped, %d failed%s"
      r.copied
      (Narrate.size r.bytes_moved)
      r.identical r.dirs (List.length r.skipped) (List.length r.failed)
      (if r.cancelled then "; cancelled before the end" else "");
    let shown p = if p = "" then "." else p in
    List.iter (fun (p, why) -> say "  skipped %s: %s" (shown p) why) r.skipped;
    List.iter (fun (p, why) -> say "  failed %s: %s" (shown p) why) r.failed);
  List.iter
    (fun p -> say "  not copied, unpublished edits here: %s" p)
    r.unpublished;
  if r.failed = [] && not r.cancelled then 0 else 1

let mirror io (dom : Tsync_domain.Domain.t) ~source ~skip_chunks ~path =
  let say fmt = Printf.ksprintf io.out fmt in
  let module M = Store_mirror.Make ((val Tsync_domain.Domain.context dom)) in
  let scope : Store_mirror.scope =
    match (skip_chunks, path) with
      | true, _ -> Skip_chunks
      | false, Some p -> Path p
      | false, None -> All
  in
  let r = M.mirror ~narrate:io.narrate ~cancelled:io.cancelled ?source scope in
  List.iter
    (fun (c : Store_mirror.copied) ->
      say "%s -> %s: %d checked, %d copied (%s), %d refused%s%s" r.source c.name
        c.checked c.copied
        (Narrate.size c.copied_bytes)
        (List.length c.failed)
        (if c.changed > 0 then
           Printf.sprintf ", %d changed since compared (next run)" c.changed
         else "")
        (if c.unguarded > 0 then
           Printf.sprintf ", %d written unguarded" c.unguarded
         else "");
      List.iter (fun (k, why) -> say "  %s: %s" k why) c.failed)
    r.copies;
  if r.cancelled then say "cancelled before the end";
  if
    r.cancelled
    || List.exists (fun (c : Store_mirror.copied) -> c.failed <> []) r.copies
  then 1
  else 0

let run io (dom : Tsync_domain.Domain.t) engine = function
  | Gc { apply; verify; abort; budget } ->
      gc io dom.composite ~apply ~verify ~abort ~budget
  | Gc_copies act -> copies io dom.composite act
  | Expire { apply; cutoff } -> expire io dom ~apply ~cutoff
  | Purge { apply; path } -> purge io dom ~apply ~path
  | Sync { full } -> (
      let module E = (val engine : Tsync_sync.Engine.S) in
      match E.resync ~narrate:io.narrate ~full () with
        | `Incremental n ->
            io.out
              (Printf.sprintf "%s from other clients"
                 (Narrate.count ~plural:"journal entries" n "journal entry"));
            0
        | `Full (manifests, failed) ->
            io.out
              (Printf.sprintf "full resync: %s%s"
                 (Narrate.count manifests "manifest")
                 (if failed > 0 then Printf.sprintf " (%d failed)" failed
                  else ""));
            if failed > 0 then 1 else 0)
  | Mirror { source; skip_chunks; path } ->
      if dom.domain.read_only then
        Fail.raise_ Fail.Read_only "%s is read-only"
          (Domain_name.to_string dom.name);
      mirror io dom ~source ~skip_chunks ~path
  | Import { src; only; exclude; force_rehash } ->
      if dom.domain.read_only then
        Fail.raise_ Fail.Read_only "%s is read-only"
          (Domain_name.to_string dom.name);
      import io engine ~src ~only ~exclude ~force_rehash
  | Rsync { src; src_in_domain; dst; dst_in_domain; move; dry_run } ->
      let side b : Tsync_sync.Rsync_plan.side = if b then Domain else Local in
      if
        dom.domain.read_only && (not dry_run)
        && (dst_in_domain || (move && src_in_domain))
      then
        Fail.raise_ Fail.Read_only "%s is read-only"
          (Domain_name.to_string dom.name);
      rsync io engine ~move ~dry_run
        ~src:{ side = side src_in_domain; path = src }
        ~dst:{ side = side dst_in_domain; path = dst }
  | Integrity { verify = true; _ } -> verify io dom
  | Integrity { repair; apply; detail; source; _ } ->
      integrity io dom ~repair ~apply ~detail ~source
