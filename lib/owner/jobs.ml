open Tsync_core
open Tsync_gc
include Tsync_protocol.Job

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
    say "  %d referenced chunks misread" s.chunks_corrupt;
  Option.iter
    (fun (e : Collector.expiry) ->
      say
        "  the expiry deletes %s (%s) and frees %d chunks (%s); with it, a \
         collection reclaims %d chunks (%s)"
        (Narrate.count e.versions "version")
        (Narrate.size e.version_bytes)
        e.chunks_freed
        (Narrate.size e.bytes_freed)
        (e.chunks_freed + s.chunks_reclaimable)
        (Narrate.size (e.bytes_freed + s.bytes_reclaimable)))
    s.expiry

let print_stats out (s : Collector.stats) =
  let say fmt = Printf.ksprintf out fmt in
  say "%s: %s; %d namespaces marked, %d chunks promoted, %d reclaimed (%s)%s"
    s.main (outcome s.outcome) s.roots_marked s.chunks_promoted
    s.chunks_reclaimed
    (Narrate.size s.bytes_reclaimed)
    (if s.versions_expired > 0 then
       Printf.sprintf ", %d versions expired" s.versions_expired
     else "");
  if s.chunks_verified > 0 then
    say "  verified %d: %d corrupt, %d unreadable, %d markers cleared"
      s.chunks_verified s.chunks_corrupt s.chunks_unreadable s.chunks_cleared

let refuse = function
  | Collector.Busy ->
      Fail.raise_ Fail.Load "another collection holds this domain's run lock"
  | Unsupported reason -> Fail.raise_ Fail.Refused "cannot collect: %s" reason
  | Refused reason -> Fail.raise_ Fail.Refused "%s" reason

(* gc §5.7: a request no function consumes keeps G odd for good, and only
   this says so. *)
let report_outstanding out c =
  match Tsync_store.Composite.outstanding c with
    | [] -> ()
    | l ->
        let oldest =
          List.fold_left
            (fun a (o : Tsync_store.Composite.outstanding) -> Float.max a o.age)
            0. l
        in
        Printf.ksprintf out
          "%s outstanding, the oldest for %s: is the bucket function deployed \
           and notified? (gc --outstanding)"
          (Narrate.count (List.length l) "discard request")
          (Narrate.duration oldest)
    | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
    | exception e ->
        Printf.ksprintf out "outstanding discard requests not read: %s"
          (Fail.classify e).reason

(* gc.md §4.1: the keys a list names, and how many lines were already gone;
   [None] once a refusal is reported, with nothing deleted. *)
let resolve_listed io (dom : Tsync_domain.Domain.t) file =
  let say fmt = Printf.ksprintf io.out fmt in
  let module E = Expiry_list.Make ((val Tsync_domain.Domain.context dom)) in
  let r = E.resolve (Expiry_list.parse (Fs.read_file file)) in
  List.iter (fun (n, why) -> say "  line %d: %s" n why) r.warnings;
  if r.rejected = [] then Some (r.matched, List.length r.absent)
  else (
    List.iter (fun (n, why) -> say "  line %d rejected: %s" n why) r.rejected;
    say "nothing expired: %s rejected"
      (Narrate.count (List.length r.rejected) "line");
    None)

let expiring_keys io (dom : Tsync_domain.Domain.t) = function
  | `Before cutoff ->
      let module C = (val Tsync_domain.Domain.context dom) in
      Some
        (Gc_plan.versions ~cutoff
           (List.map
              (fun (e : Tsync_store.Store.entry) -> e.key)
              (C.store.list_prefix (Key.versions dom.name))))
  | `Listed file -> Option.map fst (resolve_listed io dom file)

let gc io (dom : Tsync_domain.Domain.t) ~apply ~verify ~abort ~budget ~expire =
  let c = dom.composite in
  let say fmt = Printf.ksprintf io.out fmt in
  let finally () = report_outstanding io.out c in
  Fun.protect ~finally @@ fun () ->
  let refuse = function
    | Collector.Unsupported reason when expire <> None ->
        Fail.raise_ Fail.Refused
          "cannot collect: %s; tsync expire --from FILE expires a list without \
           collecting"
          reason
    | f -> refuse f
  in
  match Option.map (expiring_keys io dom) expire with
    | Some None -> 1
    | expiring ->
        let expiring = Option.join expiring in
        if apply || abort then (
          match
            Collector.run ?budget ?expiring ~narrate:io.narrate ~verify
              ~keep:abort ~cancelled:io.cancelled c
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
            Collector.dry_run ?expiring ~narrate:io.narrate ~verify
              ~cancelled:io.cancelled c
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
        let confirmed =
          List.map
            (fun (m : Tsync_store.Composite.member) ->
              say "%s: probing its bucket function (up to 3 minutes)" m.name;
              let confirmed =
                Tsync_store.Composite.probe ~cancelled:io.cancelled c m
              in
              say "  %s"
                (if confirmed then "confirmed"
                 else "not confirmed: requests were not consumed");
              confirmed)
            stores
        in
        if List.for_all Fun.id confirmed then 0 else 1
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

let write_list file text =
  let tmp = Fs.write_temp ~perm:0o644 (Filename.dirname file) text in
  Fs.unix_rename tmp file

let expire_before io (dom : Tsync_domain.Domain.t) ~apply ~cutoff ~export =
  let say fmt = Printf.ksprintf io.out fmt in
  let module C = (val Tsync_domain.Domain.context dom) in
  let module R = Retention.Make (C) in
  let module E = Expiry_list.Make (C) in
  let apply = apply && export = None in
  let now = Unix.gettimeofday () in
  let r =
    R.expire ~narrate:io.narrate ~apply ~cancelled:io.cancelled ~now ~cutoff ()
  in
  say "versions %d, log entries %d, shares %d%s%s" r.counts.versions_deleted
    r.counts.log_deleted r.counts.shares_deleted (dry_note apply)
    (if r.cancelled then "; cancelled before the end" else "");
  List.iter
    (fun k -> say "  unparseable share left: %s" (Key.to_string k))
    r.unparseable_shares;
  (match export with
    | Some _ when r.cancelled -> say "  no list written: the run was cancelled"
    | None -> ()
    | Some file ->
        let listed, unreadable =
          E.entries (List.filter (Key.under (Key.versions dom.name)) r.deleted)
        in
        write_list file (Expiry_list.print ~domain:dom.name ~cutoff ~now listed);
        say "  %s listed in %s"
          (Narrate.count (List.length listed) "version")
          file;
        List.iter
          (fun k ->
            say "  left out, its body does not read: %s" (Key.to_string k))
          unreadable);
  if r.cancelled then 1 else 0

let expire_listed io (dom : Tsync_domain.Domain.t) ~apply file =
  let say fmt = Printf.ksprintf io.out fmt in
  let module R = Retention.Make ((val Tsync_domain.Domain.context dom)) in
  match resolve_listed io dom file with
    | None -> 1
    | Some (matched, absent) ->
        let l =
          R.expire_listed ~narrate:io.narrate ~apply ~cancelled:io.cancelled
            matched
        in
        say
          "versions %d, %d already gone; log and shares untouched (tsync \
           expire DATE trims those)%s%s"
          l.versions_deleted absent (dry_note apply)
          (if l.cancelled then "; cancelled before the end" else "");
        if l.cancelled then 1 else 0

(* 05 §4.8. *)
let expire io dom ~apply ~expiry ~export =
  match expiry with
    | `Before cutoff -> expire_before io dom ~apply ~cutoff ~export
    | `Listed file -> expire_listed io dom ~apply file

(* 05 §4.12. *)
let void_entry io (dom : Tsync_domain.Domain.t) n =
  let say fmt = Printf.ksprintf io.out fmt in
  let module C = (val Tsync_domain.Domain.context dom) in
  let log = Tsync_remote.Log_store.create dom.name C.store in
  let tree_head = Tsync_remote.Log_store.tree_head log in
  match Tsync_remote.Log_store.read_entry log n with
    | _ when n <= tree_head ->
        say "entry %d is at or below the tree head (%d): nothing to void" n
          tree_head;
        1
    | None ->
        say "entry %d does not exist" n;
        1
    | Some { read = Entry _; _ } ->
        say "entry %d decodes: it is not voided" n;
        1
    | Some { read = Later_version v; _ } ->
        say "entry %d is of version %d: it needs a newer client, not a void" n v;
        1
    | Some { read = Void | Undecodable _; _ } ->
        ignore
          (Tsync_remote.Log_store.void_create log n
             ~client:(Tsync_checkout.Identity.client_uuid dom.data_dir));
        say
          "entry %d is voided: its commands are not part of the main. The \
           client that created it still holds its changes and loses them at \
           its next 'tsync sync --full'; copy aside what must be kept first."
          n;
        0

let kind_name = function
  | Integrity.Disowned _ -> "disowned markers"
  | Unmarked _ -> "folders without a marker"
  | Unaccounted _ -> "records the log does not account for"

let counted names =
  let tally = Hashtbl.create 8 in
  List.iter
    (fun n ->
      Hashtbl.replace tally n
        (1 + Option.value ~default:0 (Hashtbl.find_opt tally n)))
    names;
  List.sort compare (Hashtbl.fold (fun n k acc -> (n, k) :: acc) tally [])

let verify io (dom : Tsync_domain.Domain.t) =
  let say fmt = Printf.ksprintf io.out fmt in
  let module I = Integrity.Make ((val Tsync_domain.Domain.context dom)) in
  let results = I.verify ~narrate:io.narrate ~cancelled:io.cancelled () in
  let count = function
    | Some n -> string_of_int n
    | None -> "an unknown number of"
  in
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
          | Stalled { left = Some 0; corrupt = None } ->
              say
                "%s: every shard was checked, but its corruption markers could \
                 not be listed: the result is unknown"
                member
          | Stalled { left; corrupt } ->
              say
                "%s: stalled with %s shard requests left and %s corrupt chunks \
                 so far: is its bucket function deployed and notified?"
                member (count left) (count corrupt)
          | Abandoned { left; corrupt } ->
              say
                "%s: cancelled with %s shard requests left and %s corrupt \
                 chunks so far; its function still consumes them"
                member (count left) (count corrupt))
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
  let findings =
    match r.tree with
      | Findings f -> f
      | Behind { tree_head; head } ->
          say
            "the tree is behind its log (tree head %d, head %d): a projection \
             is owed or in progress, and no finding is made"
            tree_head head;
          []
  in
  if not repair then (
    if Integrity.healthy r then
      say "%s: healthy" (Domain_name.to_string dom.name)
    else (
      List.iter
        (fun (n, k) -> say "%d %s" k n)
        (counted (List.map kind_name findings));
      if r.corrupt <> [] then say "%d corrupt chunks" (List.length r.corrupt);
      if detail then (
        List.iter (fun f -> say "  %s" (Integrity.describe f)) findings;
        List.iter
          (fun (c : Integrity.corrupt) ->
            say "  %s marked corrupt on %s"
              (Chunk_key.to_string c.chunk)
              c.member)
          r.corrupt));
    (* 05 §4.10: a tree behind its log is not unhealthy. *)
    if Integrity.healthy r || (findings = [] && r.corrupt = []) then 0 else 1)
  else (
    let chunks =
      I.repair_chunks ~narrate:io.narrate ~apply ?source ~cancelled:io.cancelled
        r
    in
    let acted verb = if apply then verb else "would be " ^ verb in
    let chunk_outcome = function
      | Integrity.Cleared -> acted "rewritten from their own copy"
      | Repaired _ -> acted "repaired from another member"
      | Unrepairable -> "unrepairable"
    in
    List.iter
      (fun (n, k) -> say "%d %s" k n)
      (counted (List.map (fun (_, o) -> "chunks " ^ chunk_outcome o) chunks));
    if detail then
      List.iter
        (fun ((c : Integrity.corrupt), o) ->
          say "  %s on %s: %s%s"
            (Chunk_key.to_string c.chunk)
            c.member (chunk_outcome o)
            (match o with Repaired from -> " (" ^ from ^ ")" | _ -> ""))
        chunks;
    (* A cancelled repair returns only what it considered. *)
    let skipped = List.length r.corrupt - List.length chunks in
    if r.corrupt = [] then
      say "%s: no chunk to repair" (Domain_name.to_string dom.name);
    if findings <> [] then
      say "%s in the tree: reported only, nothing repairs the tree"
        (Narrate.count (List.length findings) "finding");
    if skipped > 0 then
      say "cancelled: %s not considered" (Narrate.count skipped "chunk");
    if not apply then say "(dry run: nothing changed; drop --dry-run to act)";
    if
      skipped > 0 || findings <> []
      || List.exists (fun (_, o) -> o = Integrity.Unrepairable) chunks
    then 1
    else 0)

let import io (module E : Tsync_sync.Engine.S) ~src ~only ~exclude ~force_rehash
    ~map =
  let say fmt = Printf.ksprintf io.out fmt in
  let r =
    E.import ~narrate:io.narrate ~cancelled:io.cancelled ~only ~exclude
      ~force_rehash ?map src
  in
  say
    "imported %s (%s); %d already in the domain, %d links skipped, %d failed%s"
    (Narrate.count r.imported "file")
    (Narrate.size r.bytes) r.skipped r.skipped_symlinks (List.length r.failed)
    (if r.cancelled then "; cancelled before the end" else "");
  List.iter (fun (path, reason) -> say "  %s: %s" path reason) r.failed;
  if r.uncommitted > 0 then
    say "%s made here and not committed yet; a later cycle commits them"
      (Narrate.count r.uncommitted "change");
  if r.failed = [] && r.uncommitted = 0 && not r.cancelled then 0 else 1

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
  if r.uncommitted > 0 then
    say "%s made here and not committed yet; a later cycle commits them"
      (Narrate.count r.uncommitted "change");
  if r.failed = [] && r.uncommitted = 0 && not r.cancelled then 0 else 1

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
  | Gc { apply; verify; abort; budget; expire } ->
      gc io dom ~apply ~verify ~abort ~budget ~expire
  | Gc_copies act -> copies io dom.composite act
  | Expire { apply; expiry; export } -> expire io dom ~apply ~expiry ~export
  | Void_entry { n } -> void_entry io dom n
  | Sync { full } ->
      let module E = (val engine : Tsync_sync.Engine.S) in
      let r = E.resync ~narrate:io.narrate ~full () in
      io.out
        (Printf.sprintf "%s; %s changed here; %s committed; %s pending"
           (match r.arrival with
             | `Entries n ->
                 Narrate.count ~plural:"log entries" n "log entry" ^ " merged"
             | `State (files, folders) ->
                 Printf.sprintf "arrived by state: %s, %s"
                   (Narrate.count files "file")
                   (Narrate.count folders "folder"))
           (Narrate.count r.changed "path")
           (Narrate.count ~plural:"entries" r.committed "entry")
           (Narrate.count r.pending "change"));
      0
  | Mirror { source; skip_chunks; path } ->
      if dom.domain.read_only then
        Fail.raise_ Fail.Read_only "%s is read-only"
          (Domain_name.to_string dom.name);
      mirror io dom ~source ~skip_chunks ~path
  | Import { src; only; exclude; force_rehash; map } ->
      if dom.domain.read_only then
        Fail.raise_ Fail.Read_only "%s is read-only"
          (Domain_name.to_string dom.name);
      import io engine ~src ~only ~exclude ~force_rehash ~map
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
