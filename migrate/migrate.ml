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
    "usage: migrate [--dry-run] <directory>...\n\n\
     Rewrites JSON manifest bodies as chunk-table bodies, in place.";
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
  mutable before : int;
  mutable after : int;
}

let convert ~dry_run c path =
  match read_file path with
    | exception e ->
        c.failed <- c.failed + 1;
        Printf.eprintf "FAIL  %s: %s\n" path (Printexc.to_string e)
    | body when String.length body >= 8 && String.sub body 0 8 = "tsyncm03" ->
        c.already <- c.already + 1
    | body -> (
        match parse_v2 body with
          | encoded ->
              c.converted <- c.converted + 1;
              c.before <- c.before + String.length body;
              c.after <- c.after + String.length encoded;
              if not dry_run then write_atomic path encoded
          | exception _ ->
              (* Not a manifest: a folder marker, a name marker, anything else
               sharing the tree. *)
              c.skipped <- c.skipped + 1)

let rec walk ~dry_run c path =
  match Sys.is_directory path with
    | true ->
        Array.iter
          (fun n -> walk ~dry_run c (Filename.concat path n))
          (Sys.readdir path)
    | false -> convert ~dry_run c path
    | exception Sys_error msg -> Printf.eprintf "FAIL  %s\n" msg

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let dry_run = List.mem "--dry-run" args in
  let dirs =
    List.filter (fun a -> not (String.starts_with ~prefix:"-" a)) args
  in
  if dirs = [] then usage ();
  let c =
    {
      converted = 0;
      already = 0;
      skipped = 0;
      failed = 0;
      before = 0;
      after = 0;
    }
  in
  List.iter (walk ~dry_run c) dirs;
  Printf.printf "%sconverted %d, already v3 %d, not a manifest %d, failed %d\n"
    (if dry_run then "[dry run] " else "")
    c.converted c.already c.skipped c.failed;
  if c.converted > 0 then
    Printf.printf "manifest bytes: %.1f MB -> %.1f MB (%.1fx)\n"
      (float_of_int c.before /. 1e6)
      (float_of_int c.after /. 1e6)
      (float_of_int c.before /. float_of_int (max 1 c.after));
  if c.failed > 0 then exit 1
