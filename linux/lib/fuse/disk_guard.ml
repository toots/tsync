open Lwt.Syntax

(* Preserves a minimum fraction of free space on the filesystem holding the
   local cache. When free space falls into the danger zone, downloads and
   writes are gated (they block until space recovers) and clean cached files
   are evicted, least recently used first, until free space is comfortable
   again.

   Hysteresis relative to the configured watermark [t]: the guard engages
   while free space is still 10% above the watermark (free < 1.1 x t), so the
   promised minimum is never breached, and disengages once 20% above
   (free >= 1.2 x t), so it does not flap around a single threshold. *)

module Make (C : Conf.S) (F : File.S) = struct
  let engage_factor = 1.1
  let release_factor = 1.2
  let tick_seconds = 1.
  let free_fraction () = Disk_space.free_fraction C.cache_root

  (* ── Gate ─────────────────────────────────────────────────────────────── *)

  let throttled = ref false
  let gate_opened = Lwt_condition.create ()

  let rec wait () =
    if not !throttled then Lwt.return_unit
    else
      let* () = Lwt_condition.wait gate_opened in
      wait ()

  let engage free =
    if not !throttled then begin
      throttled := true;
      Log.info "preserve-space: %.1f%% free, throttling downloads and writes"
        (100. *. free)
    end

  let release free =
    if !throttled then begin
      throttled := false;
      Log.info "preserve-space: %.1f%% free, resuming downloads and writes"
        (100. *. free);
      Lwt_condition.broadcast gate_opened ()
    end

  (* ── Eviction sweep ───────────────────────────────────────────────────── *)

  (* Data files live under cache_root/<domain_name>/; the path relative to
     that root is the key relative to the domain prefix. *)
  let cache_dir = Filename.concat C.cache_root C.domain_name

  let rec collect_cached dir rel acc =
    let* names =
      Lwt.catch
        (fun () -> Lwt_stream.to_list (Lwt_unix.files_of_directory dir))
        (fun _ -> Lwt.return_nil)
    in
    Lwt_list.fold_left_s
      (fun acc name ->
        if name = "." || name = ".." then Lwt.return acc
        else (
          let path = Filename.concat dir name in
          let rel = if rel = "" then name else rel ^ "/" ^ name in
          let* st =
            Lwt.catch
              (fun () ->
                let+ st = Lwt_unix.stat path in
                Some st)
              (fun _ -> Lwt.return_none)
          in
          match st with
            | Some { Unix.st_kind = Unix.S_DIR; _ } ->
                collect_cached path rel acc
            | Some { Unix.st_kind = Unix.S_REG; st_atime; _ } ->
                Lwt.return ((C.domain_prefix ^ rel, st_atime) :: acc)
            | _ -> Lwt.return acc))
      acc names

  (* Evictable: uploaded (clean manifest), no pending local change, no open
     handle. Dirty and open files become candidates on later ticks, once the
     upload queue has drained and handles are closed. *)
  let evictable key =
    if F.is_dirty key || F.is_open key then Lwt.return_false
    else
      let+ m = F.read_manifest key in
      match m with Some (`Clean _) -> true | _ -> false

  let lru_candidates () =
    let+ cached = collect_cached cache_dir "" [] in
    List.sort (fun (_, a) (_, b) -> compare a b) cached

  let rec evict_until ~release_level = function
    | [] -> Lwt.return_unit
    | _ when free_fraction () >= release_level -> Lwt.return_unit
    | (key, _) :: rest ->
        let* ok = evictable key in
        let* () =
          if ok then begin
            Log.info "preserve-space: evicting %s" key;
            F.evict key
          end
          else Lwt.return_unit
        in
        evict_until ~release_level rest

  (* ── Monitor loop ─────────────────────────────────────────────────────── *)

  let check () =
    match Ipc.preserve_space_percent ~data_dir:C.data_dir with
      | None -> Lwt.return (release (free_fraction ()))
      | Some pct ->
          let watermark = pct /. 100. in
          let free = free_fraction () in
          if free < engage_factor *. watermark then begin
            engage free;
            let* () =
              let* candidates = lru_candidates () in
              evict_until
                ~release_level:(release_factor *. watermark)
                candidates
            in
            let free = free_fraction () in
            Lwt.return
              (if free >= release_factor *. watermark then release free)
          end
          else
            Lwt.return
              (if free >= release_factor *. watermark then release free)

  let rec monitor () =
    let* () =
      Lwt.catch check (fun exn ->
          Log.err "preserve-space: %s" (Printexc.to_string exn);
          Lwt.return_unit)
    in
    let* () = Lwt_unix.sleep tick_seconds in
    monitor ()

  (* ── Stats ────────────────────────────────────────────────────────────── *)

  let status () =
    [
      ( "preserveSpacePercent",
        match Ipc.preserve_space_percent ~data_dir:C.data_dir with
          | Some p -> `Float p
          | None -> `Null );
      ("throttled", `Bool !throttled);
    ]
end
