open Tsync_core
open Tsync_gc

type copies = Probe | Outstanding | Retry_outstanding [@@deriving yojson]

type t =
  | Gc of { apply : bool; verify : bool; abort : bool; budget : float option }
  | Gc_copies of copies
  | Expire of { apply : bool; cutoff : float }
  | Purge of { apply : bool; path : string }
[@@deriving yojson]

let kind = function
  | Gc { abort = true; _ } -> "gc --abort"
  | Gc { apply = true; _ } -> "gc --apply"
  | Gc _ -> "gc"
  | Gc_copies Probe -> "gc --probe"
  | Gc_copies Outstanding -> "gc --outstanding"
  | Gc_copies Retry_outstanding -> "gc --retry-outstanding"
  | Expire _ -> "expire"
  | Purge _ -> "trash --purge"

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
        let copies =
          List.filter
            (fun (m : Tsync_store.Composite.member) ->
              (m.role = Replica || m.role = Backfill)
              && m.store.bucket_functions)
            (Tsync_store.Composite.members c)
        in
        if copies = [] then
          say "no copy of this domain can run a bucket function";
        List.iter
          (fun (m : Tsync_store.Composite.member) ->
            say "%s: probing its bucket function (up to 3 minutes)" m.name;
            say "  %s"
              (if Tsync_store.Composite.probe c m then "confirmed"
               else "not confirmed: requests were not consumed"))
          copies;
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

let run io (dom : Tsync_domain.Domain.t) = function
  | Gc { apply; verify; abort; budget } ->
      gc io dom.composite ~apply ~verify ~abort ~budget
  | Gc_copies act -> copies io dom.composite act
  | Expire { apply; cutoff } -> expire io dom ~apply ~cutoff
  | Purge { apply; path } -> purge io dom ~apply ~path
