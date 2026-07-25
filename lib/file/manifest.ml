(* Chunk size for newly uploaded files. Overridable via [TSYNC_CHUNK_SIZE] so
   tests can exercise multi-chunk files without multi-megabyte fixtures; each
   manifest also records its own [chunk_size], so existing files are unaffected. *)
let chunk_size =
  match Sys.getenv_opt "TSYNC_CHUNK_SIZE" with
    | Some s -> ( try int_of_string s with _ -> 8 * 1024 * 1024)
    | None -> 8 * 1024 * 1024

(* Manifest body format version. 2 = inode layout (bodies carry the leaf [name];
   folder structure lives in markers). Bumped from 1 (real-path-keyed layout) by
   the one-off migration. Nothing branches on it today; it flags the format. *)
let current_version = 2

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

(* Per-chunk residency of a locally cached file. [Present] = fetched and matches
   the backend; [Absent] = a hole (never fetched); [Dirty] = written locally,
   not yet published (its [chunk_entry] hashes are stale, recomputed at upload).
   The whole-file [residency] is [None] for a fully present, clean file — the
   only form published to the backend, byte-identical to a file with no partial
   state. *)
type chunk_st = Present | Absent | Dirty

type t = {
  v : int;
  name : string;  (** leaf name; authority for the file's own name *)
  size : int64;
  chunk_size : int;
  chunks : chunk_entry list;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
  residency : chunk_st array option;
      (** [None] = fully present and clean; [Some a] = per-chunk state of a
          partially cached or partially edited file (index-aligned to [chunks]).
      *)
}

type state = [ `Dirty | `Clean of t ]

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

(* Whole-file digest as a hash over the ordered chunk digests, so a changed
   file's manifest is rebuildable from its chunk entries alone (no need to
   re-read untouched chunk bytes). Seeds 0/1 give the two independent hashes. *)
let digest_of_chunks chunks =
  let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
  List.iter
    (fun (c : chunk_entry) ->
      let d = Printf.sprintf "%s-%s-%d;" c.h1 c.h2 c.size in
      Xxhash.update s1 d;
      Xxhash.update s2 d)
    chunks;
  (Xxhash.digest_hex s1, Xxhash.digest_hex s2)

let make ~name ~h1 ~h2 ~size ~chunk_size ~chunks ~mtime =
  `Clean
    {
      v = current_version;
      name;
      size;
      chunk_size;
      chunks;
      h1;
      h2;
      mtime;
      symlink = None;
      residency = None;
    }

(* A symlink is a chunkless manifest carrying its target. size is the target's
   byte length, POSIX-style. *)
let make_symlink ~name ~target ~mtime =
  let h1 = Xxhash.hash_hex target 0 in
  let h2 = Xxhash.hash_hex target 1 in
  `Clean
    {
      v = current_version;
      name;
      size = Int64.of_int (String.length target);
      chunk_size;
      chunks = [];
      h1;
      h2;
      mtime;
      symlink = Some target;
      residency = None;
    }

let of_json json =
  let open Yojson.Basic.Util in
  if try json |> member "dirty" |> to_bool with _ -> false then `Dirty
  else (
    (* A malformed chunk list must fail the parse: defaulting to [] would make
       a corrupt manifest read as a clean, chunkless file and download as
       zero-filled bytes of the stated size. Real files always have >= 1 chunk
       (even empty ones); only symlink manifests are legitimately chunkless. *)
    let chunks =
      json |> member "chunks" |> to_list
      |> List.map (fun c ->
          {
            index = c |> member "index" |> to_int;
            h1 = c |> member "h1" |> to_string;
            h2 = c |> member "h2" |> to_string;
            size = c |> member "size" |> to_int;
          })
    in
    let symlink =
      match json |> member "symlink" with `String s -> Some s | _ -> None
    in
    if chunks = [] && symlink = None then failwith "manifest: empty chunk list";
    let residency =
      match json |> member "residency" with
        | `List l ->
            Some
              (Array.of_list
                 (List.map
                    (fun j ->
                      match to_string j with
                        | "A" -> Absent
                        | "D" -> Dirty
                        | _ -> Present)
                    l))
        | _ -> None
    in
    `Clean
      {
        v = (try json |> member "v" |> to_int with _ -> 1);
        name = json |> member "name" |> to_string;
        size = json |> member "size" |> to_int |> Int64.of_int;
        chunk_size =
          (try json |> member "chunkSize" |> to_int with _ -> chunk_size);
        chunks;
        h1 = (try json |> member "h1" |> to_string with _ -> "");
        h2 = (try json |> member "h2" |> to_string with _ -> "");
        mtime = json |> member "mtime" |> to_float;
        symlink;
        residency;
      })

let of_string s = of_json (Yojson.Basic.from_string s)

let to_json = function
  | `Dirty -> `Assoc [("dirty", `Bool true)]
  | `Clean m ->
      `Assoc
        ([
           ("v", `Int m.v);
           ("name", `String m.name);
           ("size", `Int (Int64.to_int m.size));
           ("chunkSize", `Int m.chunk_size);
           ("h1", `String m.h1);
           ("h2", `String m.h2);
           ("mtime", `Float m.mtime);
           ( "chunks",
             `List
               (List.map
                  (fun c ->
                    `Assoc
                      [
                        ("index", `Int c.index);
                        ("h1", `String c.h1);
                        ("h2", `String c.h2);
                        ("size", `Int c.size);
                      ])
                  m.chunks) );
         ]
        @ (match m.symlink with
          | None -> []
          | Some t -> [("symlink", `String t)])
        @
          match m.residency with
          | None -> []
          | Some arr ->
              [
                ( "residency",
                  `List
                    (Array.to_list
                       (Array.map
                          (fun s ->
                            `String
                              (match s with
                                | Present -> "P"
                                | Absent -> "A"
                                | Dirty -> "D"))
                          arr)) );
              ])

let to_string state = Yojson.Basic.to_string (to_json state)
