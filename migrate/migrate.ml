(* Rewrite JSON manifest bodies as {!Chunk_table} bodies, in place.

   Point it at a directory and it walks everything underneath, converting every
   file whose body parses as a JSON manifest and leaving everything else alone —
   folder markers, name markers, chunk bodies, journal entries. It is safe to
   re-run: a body that is already a chunk table is skipped.

   Two trees need this. The local manifest mirror,
   [<cache_root>/<domain>/manifests], and — for a domain on a local-file backend
   — the backend's own [manifests/] tree. A domain on S3 or GCS has its bodies
   in the bucket, which this cannot reach; those are converted by pointing this
   at a synced local copy and putting it back, or by re-uploading.

   This is the only reader of the old format left. It goes once every domain has
   been converted. *)

let usage () =
  prerr_endline
    "usage: migrate [--dry-run] [--quiet] <directory>...\n\n\
     Rewrites JSON manifest bodies as chunk-table bodies, in place. Reports\n\
     every file it looks at; --quiet leaves only the summary and any failures.";
  exit 2

(* The old body. Chunk entries carried their index and length explicitly; both
   are positional or derivable now, so only the digests survive. *)
let parse_v2 body =
  let open Yojson.Basic.Util in
  let json = Yojson.Basic.from_string body in
  let chunks = json |> member "chunks" |> to_list in
  let symlink =
    match json |> member "symlink" with `String s -> Some s | _ -> None
  in
  if chunks = [] && symlink = None then failwith "empty chunk list";
  (* [index] was authoritative, and a body could in principle carry them out of
     order; position is authoritative now, so order by it before dropping it. *)
  let keys =
    chunks
    |> List.map (fun c ->
        ( c |> member "index" |> to_int,
          (c |> member "h1" |> to_string) ^ "-" ^ (c |> member "h2" |> to_string)
        ))
    |> List.sort (fun (a, _) (b, _) -> compare a b)
    |> List.map snd
  in
  let str k = json |> member k |> to_string in
  Chunk_table.encode ~name:(str "name")
    ~size:(json |> member "size" |> to_int |> Int64.of_int)
    ~chunk_size:
      (try json |> member "chunkSize" |> to_int
       with _ -> Conf.default_chunk_size)
    ~mtime:(json |> member "mtime" |> to_float)
    ~h1:(str "h1") ~h2:(str "h2") ~symlink ~keys

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Replace by rename, never in place: a reader may be holding a mapping of the
   old inode, and truncating under it would fault. *)
let write_atomic path data =
  let tmp = path ^ ".migrate.tmp" in
  let oc = open_out_bin tmp in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc data);
  Sys.rename tmp path

type counts = {
  mutable converted : int;
  mutable already : int;
  mutable skipped : int;
  mutable failed : int;
  mutable seen : int;
  mutable before : int;
  mutable after : int;
  mutable biggest : (int * int * string) option;  (** before, after, path *)
  total : int;  (** files found by the counting pass, for the progress column *)
}

let kb n = float_of_int n /. 1024.

(* Buffered output would leave a long run looking hung; flushing every line
   costs nothing next to reading and rewriting each file. *)
let say fmt =
  Printf.ksprintf
    (fun s ->
      print_string s;
      flush stdout)
    fmt

let progress c =
  Printf.sprintf "[%*d/%d]"
    (String.length (string_of_int c.total))
    c.seen c.total

let convert ~dry_run ~quiet c path =
  c.seen <- c.seen + 1;
  match read_file path with
    | exception e ->
        c.failed <- c.failed + 1;
        Printf.eprintf "%s FAIL %s: %s\n%!" (progress c) path
          (Printexc.to_string e)
    | body when String.length body >= 8 && String.sub body 0 8 = "tsyncm03" ->
        c.already <- c.already + 1;
        if not quiet then say "%s v3   %s\n" (progress c) path
    | body -> (
        match parse_v2 body with
          | encoded ->
              let before = String.length body
              and after = String.length encoded in
              c.converted <- c.converted + 1;
              c.before <- c.before + before;
              c.after <- c.after + after;
              (match c.biggest with
                | Some (b, _, _) when b >= before -> ()
                | _ -> c.biggest <- Some (before, after, path));
              if not quiet then
                say "%s conv %6.1f KB -> %6.1f KB  %s\n" (progress c)
                  (kb before) (kb after) path;
              if not dry_run then write_atomic path encoded
          | exception _ ->
              (* Not a manifest: a folder marker, a name marker, anything else
                 sharing the tree. *)
              c.skipped <- c.skipped + 1;
              if not quiet then say "%s skip %s\n" (progress c) path)

let rec walk ~dry_run ~quiet c path =
  match Sys.is_directory path with
    | true ->
        let names = Sys.readdir path in
        Array.sort compare names;
        Array.iter
          (fun n -> walk ~dry_run ~quiet c (Filename.concat path n))
          names
    | false -> convert ~dry_run ~quiet c path
    | exception Sys_error msg ->
        c.failed <- c.failed + 1;
        Printf.eprintf "FAIL %s\n%!" msg

(* Files under [path], so the running output can say how far along it is. Only
   readdir, no bodies read. *)
let rec count_files path =
  match Sys.is_directory path with
    | true ->
        Array.fold_left
          (fun n c -> n + count_files (Filename.concat path c))
          0 (Sys.readdir path)
    | false -> 1
    | exception Sys_error _ -> 0

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let dry_run = List.mem "--dry-run" args in
  let quiet = List.mem "--quiet" args in
  let dirs =
    List.filter (fun a -> not (String.starts_with ~prefix:"-" a)) args
  in
  if dirs = [] then usage ();
  List.iter
    (fun d ->
      if not (Sys.file_exists d) then (
        Printf.eprintf "no such directory: %s\n" d;
        exit 2))
    dirs;
  if dry_run then say "Dry run: nothing will be written.\n";
  say "Scanning %s ...\n" (String.concat ", " dirs);
  let total = List.fold_left (fun n d -> n + count_files d) 0 dirs in
  say "%d files to examine.\n\n" total;
  let started = Unix.gettimeofday () in
  let c =
    {
      converted = 0;
      already = 0;
      skipped = 0;
      failed = 0;
      seen = 0;
      before = 0;
      after = 0;
      biggest = None;
      total;
    }
  in
  List.iter (walk ~dry_run ~quiet c) dirs;
  let elapsed = Unix.gettimeofday () -. started in
  say "\n%s%d converted, %d already v3, %d not a manifest, %d failed  (%.1fs)\n"
    (if dry_run then "[dry run] " else "")
    c.converted c.already c.skipped c.failed elapsed;
  if c.converted > 0 then (
    say "manifest bytes: %.1f MB -> %.1f MB, saving %.1f MB (%.1fx smaller)\n"
      (float_of_int c.before /. 1e6)
      (float_of_int c.after /. 1e6)
      (float_of_int (c.before - c.after) /. 1e6)
      (float_of_int c.before /. float_of_int (max 1 c.after));
    match c.biggest with
      | Some (b, a, path) ->
          say "largest:        %.1f KB -> %.1f KB  %s\n" (kb b) (kb a) path
      | None -> ());
  if c.failed > 0 then (
    say "\n%d file(s) failed; nothing was written for those.\n" c.failed;
    exit 1)
