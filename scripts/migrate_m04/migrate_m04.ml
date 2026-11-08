(* One-off rewrite of a stopped local store from tsyncm03 to tsyncm04 (02 §2.6):
   file manifests, versions and the manifests log entries carry; folder
   indexes, a cache of the old bodies, are deleted. Dry run unless --apply,
   then a check pass that must find nothing left to convert.

   usage: migrate_m04 [--apply] [--jobs N] STORE_ROOT DOMAIN... *)

open Tsync_core
open Tsync_store

let log fmt =
  Printf.ksprintf
    (fun s ->
      let t = Unix.localtime (Unix.time ()) in
      Printf.printf "%04d-%02d-%02d %02d:%02d:%02d %s\n%!" (t.tm_year + 1900)
        (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min t.tm_sec s)
    fmt

let old_magic = "tsyncm03"
let old_header = 72
let u32 s o = Int32.to_int (String.get_int32_le s o) land 0xffffffff

(* The tsyncm03 reader, here only: the library reads tsyncm04 alone. *)
let convert body =
  let n = String.length body in
  if n < old_header || String.sub body 0 8 <> old_magic then
    Error "not a tsyncm03 manifest"
  else (
    let size = Int64.to_int (String.get_int64_le body 8)
    and mtime = Int64.float_of_bits (String.get_int64_le body 16)
    and chunk_size = u32 body 24
    and count = u32 body 28
    and name_len = u32 body 32
    and link_len = u32 body 36 in
    let h1 = String.sub body 40 16 and h2 = String.sub body 56 16 in
    let keys_at = old_header + name_len + link_len in
    if size < 0 || keys_at + (33 * count) <> n then Error "inconsistent length"
    else (
      let name = String.sub body old_header name_len in
      let ns = Int.of_float (Float.round (mtime *. 1e9)) in
      let times = { Fs.mtime = ns; created = ns } in
      let m =
        if link_len > 0 then
          Manifest.symlink ~name ~times
            (String.sub body (old_header + name_len) link_len)
        else (
          let keys =
            List.init count (fun i ->
                match
                  Chunk_key.of_string (String.sub body (keys_at + (33 * i)) 33)
                with
                  | Some k -> k
                  | None -> failwith "a malformed chunk key")
          in
          Manifest.make ~name ~size ~times ~chunk_size keys)
      in
      if m.h1 <> h1 || m.h2 <> h2 then Error "its digest does not rebuild"
      else Ok m.body))

let is_old body = String.length body >= 8 && String.sub body 0 8 = old_magic

let rewrite_entry body =
  let convert_after = function
    | `String b64 as v -> (
        match Base64.decode b64 with
          | Ok raw when is_old raw -> (
              match convert raw with
                | Ok m -> `String (Base64.encode_string m)
                | Error e -> failwith e)
          | _ -> v)
    | v -> v
  in
  let command = function
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (k, v) ->
               if k = "after" then (k, convert_after v) else (k, v))
             fields)
    | v -> v
  in
  match Yojson.Safe.from_string body with
    | `Assoc fields ->
        let fields =
          List.map
            (fun (k, v) ->
              match (k, v) with
                | "commands", `List l -> (k, `List (List.map command l))
                | _ -> (k, v))
            fields
        in
        let out = Yojson.Safe.to_string (`Assoc fields) in
        (match Log_entry.decode out with
          | `Entry _ -> ()
          | `Later_version v -> failwith (Printf.sprintf "version %d" v)
          | `Corrupt what -> failwith ("does not decode: expected " ^ what));
        out
    | _ -> failwith "not a JSON object"

type tally = {
  mutable seen : int;
  mutable converted : int;
  mutable already : int;
  mutable indexes : int;
  mutable failed : (string * string) list;
}

let leaf key =
  let s = Key.to_string key in
  String.sub s
    (String.rindex s '/' + 1)
    (String.length s - String.rindex s '/' - 1)

(* What one key becomes: [`Put body], [`Delete], or [`Keep]. *)
let plan ~area key body =
  match area with
    | `Manifests when leaf key = ".tsync-index" -> `Delete
    | `Manifests | `Versions ->
        if is_old body then (
          match convert body with Ok m -> `Put m | Error e -> failwith e)
        else if Manifest.decode body <> None then `Already
        else `Keep
    | `Log ->
        if String.length body > 0 && body.[0] = '{' then (
          let out = rewrite_entry body in
          if out = body then `Already else `Put out)
        else `Keep

let run ~apply ~jobs (store : Store.t) domain =
  let t = { seen = 0; converted = 0; already = 0; indexes = 0; failed = [] } in
  let m = Mutex.create () in
  let one ~area (e : Store.entry) =
    let outcome =
      try
        let outcome =
          match store.get_opt e.key with
            | None -> `Keep
            | Some b -> plan ~area e.key (Bigstring.to_string b)
        in
        (match outcome with
          | `Put body when apply -> store.put e.key (Bigstring.of_string body)
          | `Delete when apply -> ignore (store.delete e.key)
          | _ -> ());
        outcome
      with
        | Failure why -> `Failed why
        | exn -> `Failed (Printexc.to_string exn)
    in
    Mutex.protect m (fun () ->
        t.seen <- t.seen + 1;
        (match outcome with
          | `Put _ -> t.converted <- t.converted + 1
          | `Delete -> t.indexes <- t.indexes + 1
          | `Already -> t.already <- t.already + 1
          | `Keep -> ()
          | `Failed why -> t.failed <- (Key.to_string e.key, why) :: t.failed);
        if t.seen mod 10000 = 0 then
          log "  %s: %d read, %d to convert, %d failed" domain t.seen
            t.converted (List.length t.failed))
  in
  List.iter
    (fun (area, sub) ->
      let prefix = Key.prefix (Printf.sprintf "tsync/%s/%s/" domain sub) in
      let entries = store.list_prefix prefix in
      log "%s/%s: %d objects" domain sub (List.length entries);
      let queue = Queue.of_seq (List.to_seq entries) in
      let qm = Mutex.create () in
      let rec worker () =
        match Mutex.protect qm (fun () -> Queue.take_opt queue) with
          | Some e ->
              one ~area e;
              worker ()
          | None -> ()
      in
      List.iter Thread.join (List.init jobs (fun _ -> Thread.create worker ())))
    [(`Log, "log"); (`Versions, "versions"); (`Manifests, "manifests")];
  log "%s: %d read, %d %s, %d already tsyncm04, %d folder indexes %s, %d failed"
    domain t.seen t.converted
    (if apply then "converted" else "to convert")
    t.already t.indexes
    (if apply then "deleted" else "to delete")
    (List.length t.failed);
  List.iter (fun (k, why) -> log "  FAILED %s: %s" k why) t.failed;
  t

let () =
  let apply = ref false and jobs = ref 8 and rest = ref [] in
  Arg.parse
    [
      ("--apply", Arg.Set apply, " write the conversion (default: dry run)");
      ("--jobs", Arg.Set_int jobs, "N objects handled at once (default 8)");
    ]
    (fun a -> rest := !rest @ [a])
    "migrate_m04 [--apply] [--jobs N] STORE_ROOT DOMAIN...";
  match !rest with
    | root :: (_ :: _ as domains) ->
        let store = Local.create ~name:"main" root in
        log "%s %s, domains: %s"
          (if !apply then "APPLY" else "dry run")
          root
          (String.concat ", " domains);
        let ok =
          List.for_all
            (fun d ->
              let t = run ~apply:!apply ~jobs:!jobs store d in
              if t.failed <> [] then false
              else if not !apply then true
              else (
                log "%s: checking" d;
                let c = run ~apply:false ~jobs:!jobs store d in
                c.failed = [] && c.converted = 0 && c.indexes = 0))
            domains
        in
        log "%s" (if ok then "done" else "FAILED");
        exit (if ok then 0 else 1)
    | _ ->
        prerr_endline
          "usage: migrate_m04 [--apply] [--jobs N] STORE_ROOT DOMAIN...";
        exit 2
