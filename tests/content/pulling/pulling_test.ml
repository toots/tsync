(* Which file a network fetch belongs to, while an ordinary read is what caused
   it.

   A mount is a network filesystem, so reading a file that is not cached blocks
   on a backend. The count of chunk fetches in flight says nothing about which
   file is waiting, and the chunk store cannot say either — a group is keyed by
   content, so two files can share one fetch. What is asserted here is that a
   read attributes its fetches to the file being read, that a read served
   locally attributes nothing, that a row goes away once it falls quiet, and
   that a whole-file materialization is credited for what it pulls down.

   Chunk sizes are tiny, so one small file spans several groups: the shape of a
   large file, in bytes. *)

open Lwt.Syntax
open Check

let chunk_size = 4096
let cache_chunk_size = 4 * chunk_size
let root = Filename.temp_dir "tsync-pulling" ""
let backend_root = Filename.concat root "backend"

(* [why] runs only on failure, so a passing run prints what the snapshot
   records. *)

module C = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = "tsync/test/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some backend_root)

  let members = [Backend.member ~name:"local" store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_chunk_buffers = 4
  let max_downloads = 16
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module D = Data.Make (C) (R)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

(* Salted so two fixtures share no chunk: a group is keyed by content, so a file
   made of another one's bytes finds them already local and pulls nothing. *)
let distinct ?(salt = 0) n =
  String.init n (fun i -> Char.chr (((i * 7) + salt) mod 251))

let size = 40 * chunk_size

(* A fixture that has to come down: uploading leaves every group local, so what
   is published is forgotten again before anyone looks at a pull. *)
let publish ~salt name =
  let key = C.domain_prefix ^ name in
  let src = Filename.concat root name in
  write_file src (distinct ~salt size);
  let* (_ : Manifest.t) =
    R.upload ~key ~src_path:src ~mtime:0. ~chunk_size ()
  in
  let+ () = D.forget_chunks key in
  key

(* Reads one cache chunk's worth at [offset], as a frontend serving a read
   does. *)
let read_at key ~offset =
  let buf =
    Bigarray.Array1.create Bigarray.char Bigarray.c_layout cache_chunk_size
  in
  D.pread_key key buf ~offset:(Int64.of_int offset)

let row_for key =
  List.find_opt (fun (p : D.pulling) -> p.D.key = key) (D.pulling_now ())

(* Prunes every row, so what comes next is measured against an empty table. *)
let forget_rows () =
  ignore (D.pulling_now ~now:(Unix.gettimeofday () +. 3600.) ())

let describe () =
  let rows = D.pulling_now () in
  Printf.sprintf "%d row(s): %s" (List.length rows)
    (String.concat ", "
       (List.map
          (fun (p : D.pulling) ->
            Printf.sprintf "%s %d/%d"
              (Filename.basename p.D.key)
              p.D.bytes p.D.size)
          rows))

let () =
  Lwt_main.run
    (let* key = publish ~salt:0 "movie.bin" in

     (* Nothing has been read, so nothing is waiting on the network. *)
     check "idle before any read" ~why:describe (D.pulling_now () = []);

     let* (_ : int) = read_at key ~offset:0 in

     (match row_for key with
       | None ->
           check "a cold read is attributed to its file" ~why:describe false
       | Some row ->
           check "a cold read is attributed to its file" true;
           (* The group that came down, not the slice that was asked for. *)
           check "it counts the bytes that crossed the wire"
             ~why:(fun () -> Printf.sprintf "bytes=%d" row.D.bytes)
             (row.D.bytes > 0);
           (* From the manifest, so a caller can say "x of y" without going near
              the store. *)
           check "it carries the whole file's size"
             ~why:(fun () -> Printf.sprintf "size=%d want=%d" row.D.size size)
             (row.D.size = size));

     let before = match row_for key with Some r -> r.D.bytes | None -> -1 in
     let* (_ : int) = read_at key ~offset:0 in
     let after = match row_for key with Some r -> r.D.bytes | None -> -1 in
     check "re-reading what is now local adds nothing"
       ~why:(fun () -> Printf.sprintf "before=%d after=%d" before after)
       (before = after && before > 0);

     (* A second file gets its own row rather than joining the first. *)
     let* other = publish ~salt:1 "other.bin" in
     let* (_ : int) = read_at other ~offset:0 in
     check "two files being read are two rows" ~why:describe
       (row_for key <> None && row_for other <> None);

     (* Far enough ahead that the idle window has passed. *)
     let later = Unix.gettimeofday () +. 3600. in
     check "a row that has fallen quiet goes away" ~why:describe
       (D.pulling_now ~now:later () = []);

     (* A materialization has no read of its own to credit: it fetches every
        group up front, so the reassembly that follows finds them local. The
        fetch credits it instead, or a file pulled from the frontend shows in the
        tray as a count with no rows under it. *)
     let* whole = publish ~salt:2 "whole.bin" in
     let* () = D.ensure_local whole in
     (match row_for whole with
       | None ->
           check "a materialization is attributed to its file" ~why:describe
             false
       | Some row ->
           check "a materialization is attributed to its file" true;
           check "it credits every group that came down"
             ~why:(fun () -> Printf.sprintf "bytes=%d want=%d" row.D.bytes size)
             (row.D.bytes = size));

     (* Only what crossed the wire counts, or a part-cached file credits its
        local groups at once and reads as a rate in the gigabytes. A first read
        never reads ahead, so exactly the group it lands in is local. *)
     let* partial = publish ~salt:3 "partial.bin" in
     let* (_ : int) = read_at partial ~offset:0 in
     forget_rows ();
     let* () = D.ensure_local partial in
     (match row_for partial with
       | None ->
           check "a group already local is not credited" ~why:describe false
       | Some row ->
           check "a group already local is not credited"
             ~why:(fun () ->
               Printf.sprintf "bytes=%d want=%d" row.D.bytes
                 (size - cache_chunk_size))
             (row.D.bytes = size - cache_chunk_size);
           (* Against what the file owes the network, so a caller can say
              "x of y" without going near the store. *)
           check "it is still measured against the whole file"
             ~why:(fun () -> Printf.sprintf "size=%d want=%d" row.D.size size)
             (row.D.size = size));

     Printf.printf "\n%s\n"
       (if failures () = 0 then "all ok"
        else Printf.sprintf "%d FAILED" (failures ()));
     report ();
     Lwt.return_unit)
