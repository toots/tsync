(* How many staged chunk bodies a chunked upload holds at once.

   Fillers take a [chunk_slots] slot, so the fan-out may be as wide as it likes
   and what is measured here is bodies live at once, not parallelism.

   The bound is load-bearing rather than an allocation cache: bypass it and a
   730 MB staged file holds all 88 of its 8 MB chunks, which OOM-kills a 415 MB
   machine set to maxChunkBuffers 4. *)

open Lwt.Syntax

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

let root = Filename.temp_dir "tsync-staged-fanout" ""
let backend_root = Filename.concat root "backend"
let csize = 64
let buffers = 4
let chunks = 32

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
  let max_chunk_buffers = buffers
  let max_downloads = 8
  let chunk_size = Some csize
  let cache_chunk_size = Some csize
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)

(* A body is live from the moment [source] is asked for it until the upload of
   it finishes, so the count is taken inside [source] and the pauses keep it
   there long enough for any concurrent caller to be seen. Unbounded, all
   [chunks] arrive before the first pause resolves. *)
let live = ref 0
let peak = ref 0

let source index =
  Lwt.return
    (`Fill
       (fun buf ->
         incr live;
         if !live > !peak then peak := !live;
         let rec settle n =
           if n = 0 then Lwt.return_unit
           else Lwt.bind (Lwt.pause ()) (fun () -> settle (n - 1))
         in
         let+ () = settle 5 in
         Bigarray.Array1.fill buf (Char.chr (index land 0x7f));
         decr live))

let () =
  Lwt_main.run
    (let* state =
       R.upload_chunks ~key:"staged.bin"
         ~size:(Int64.of_int (chunks * csize))
         ~chunk_size:csize ~mtime:0. ~source ()
     in
     Printf.printf "  %d chunks, %d buffers, peak %d live at once\n%!" chunks
       buffers !peak;

     (* The bound is on bodies in flight, so memory cannot scale with the file. *)
     check "live bodies do not scale with the file" (!peak <= buffers);
     check "but the upload is not serialised either" (!peak > 1);
     check "every chunk still lands"
       (Manifest.num_chunks_for state.Manifest.size csize = chunks);
     Lwt.return_unit);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
