open Lwt.Syntax

type op =
  | Put of { key : string; data : string }
  | Copy of { src_key : string; dst_key : string }
  | Delete of string
  | Delete_multi of string list

type stats = { queued : int; in_flight : int; degraded : bool }

(* What a target still owes. Bodyless on purpose: see the .mli. *)
type job =
  | Job_put of string
  | Job_copy of string * string
  | Job_delete of string
  | Job_delete_multi of string list

module Q = Durable_queue.Make (struct
  type t = job

  let to_string job =
    Yojson.Basic.to_string
      (match job with
        | Job_put key -> `Assoc [("op", `String "put"); ("key", `String key)]
        | Job_copy (src, dst) ->
            `Assoc
              [
                ("op", `String "copy");
                ("src", `String src);
                ("dst", `String dst);
              ]
        | Job_delete key ->
            `Assoc [("op", `String "delete"); ("key", `String key)]
        | Job_delete_multi keys ->
            `Assoc
              [
                ("op", `String "delete_multi");
                ("keys", `List (List.map (fun k -> `String k) keys));
              ])

  let of_string body =
    let open Yojson.Basic.Util in
    match Yojson.Basic.from_string body with
      | exception _ -> None
      | json -> (
          match json |> member "op" |> to_string with
            | "put" -> Some (Job_put (json |> member "key" |> to_string))
            | "copy" ->
                Some
                  (Job_copy
                     ( json |> member "src" |> to_string,
                       json |> member "dst" |> to_string ))
            | "delete" -> Some (Job_delete (json |> member "key" |> to_string))
            | "delete_multi" ->
                Some
                  (Job_delete_multi
                     (json |> member "keys" |> to_list |> List.map to_string))
            | _ -> None
            | exception _ -> None)
end)

module type S = sig
  val name : string
  val backend : (module Backend.S)
  val accept : op -> unit Lwt.t
  val skip : string -> bool
  val readable : (module Backend.S) option
  val stats : unit -> stats
end

(* Past this, a chunk PUT is dropped rather than held in memory: the manifest job
   fetches it later. *)
let max_chunks_in_flight = 32

(* ponytail: crude memo — reset the whole table past the cap rather than keeping
   an LRU, overflowing costing only a HEAD per chunk again. Per-key eviction if
   the extra HEADs ever show up in a profile. *)
let max_ensured = 100_000

(* A target's directory is named after the store, which is whatever the config
   says, so anything outside the safe set becomes [%XX] and a name with a slash
   in it cannot climb out of the root. *)
let escape name =
  let buf = Buffer.create (String.length name) in
  String.iter
    (fun c ->
      match c with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' ->
            Buffer.add_char buf c
        | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    name;
  Buffer.contents buf

let make ?(resume = false) ?chunk_from_prefix ~name ~backend ~source
    ~chunk_prefix ~(chunk_keys : string -> string list) ~journal_prefix
    ~cursor_key ~root () : (module S) =
  let (module Target : Backend.S) = backend in
  let (module Source : Backend.S) = source in
  (* Skips a HEAD per chunk, which is what makes a copy of an already-filled
     file nearly free. *)
  let ensured : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
  let remember key =
    if Hashtbl.length ensured >= max_ensured then Hashtbl.reset ensured;
    Hashtbl.replace ensured key ()
  in
  let chunks_in_flight = ref 0 in
  let quiet = Lwt_condition.create () in
  (* The source may be mid-collection, in which case a chunk not yet promoted is
     only under the from-space prefix.

     The key written to the target is the plain one either way: a target has one
     space, and never learns the source had two. *)
  let source_body key chunk_key =
    let* data = Source.get_opt ~key () in
    match (data, chunk_from_prefix) with
      | Some data, _ -> Lwt.return data
      | None, None -> Source.get ~key ()
      | None, Some prefix ->
          Source.get ~key:(prefix ^ Chunk_layout.relative_path chunk_key) ()
  in
  let ensure_chunk chunk_key =
    let key = chunk_prefix ^ Chunk_layout.relative_path chunk_key in
    if Hashtbl.mem ensured key then Lwt.return_unit
    else
      let* head = Target.head_opt ~key () in
      let* () =
        match head with
          | Some _ -> Lwt.return_unit
          | None ->
              let* data = source_body key chunk_key in
              Target.put ~key ~data ()
      in
      remember key;
      Lwt.return_unit
  in
  let rec run job =
    match job with
      | Job_put key -> (
          let* data = Source.get_opt ~key () in
          match data with
            (* Gone from the source since: a later delete, queued behind this,
               says so. *)
            | None -> Lwt.return_unit
            | Some data ->
                let* () = Lwt_list.iter_s ensure_chunk (chunk_keys data) in
                Target.put ~key ~data ())
      | Job_copy (src, dst) ->
          Lwt.catch
            (fun () -> Target.copy ~src_key:src ~dst_key:dst ())
            (fun _ ->
              (* The target has no [src]: added after it was written, or its job
                 was dropped. The authoritative [dst] exists by now, so rebuild
                 from that, chunk check included. *)
              run (Job_put dst))
      | Job_delete key ->
          Hashtbl.remove ensured key;
          Target.delete ~key ()
      | Job_delete_multi keys ->
          List.iter (fun k -> Hashtbl.remove ensured k) keys;
          Target.delete_multi keys
  in
  let queue =
    Q.ordered ~name:("deferred " ^ name)
      ~log:(Q.Records.create ~dir:(Filename.concat root (escape name)))
        (* A permanent failure is dropped: the same request would be refused
           again, and every later rename would queue behind it forever. The
           target is degraded from then on and needs resync-remote. *)
      ~poison:Durable_queue.Drop ~run ()
  in
  Q.start ~recover:resume queue;
  (* Chunk pushes are not owed — a manifest job fetches whatever is missing — but
     one still in flight when a command exits would land after everything else
     has gone quiet. *)
  let rec chunks_quiet () =
    if !chunks_in_flight = 0 then Lwt.return_unit
    else
      let* () = Lwt_condition.wait quiet in
      chunks_quiet ()
  in
  Durable_queue.register_settle chunks_quiet;
  (* Best-effort and unrecorded: correctness rests entirely on the manifest job's
     chunk check, so dropping one only costs that job a fetch.

     Dedup means a file copy or an incremental re-upload issues no chunk PUTs at
     all, which is why the durable log holds one record per user-visible
     operation rather than one per chunk. *)
  let forward_chunk key data =
    if Hashtbl.mem ensured key || !chunks_in_flight >= max_chunks_in_flight then
      ()
    else begin
      incr chunks_in_flight;
      Lwt.async (fun () ->
          Lwt.finalize
            (fun () ->
              Lwt.catch
                (fun () ->
                  let+ () = Target.put ~key ~data () in
                  remember key)
                (fun exn ->
                  Log.warn "deferred %s chunk %s: %s" name key
                    (Printexc.to_string exn);
                  Lwt.return_unit))
            (fun () ->
              decr chunks_in_flight;
              Lwt_condition.broadcast quiet ();
              Lwt.return_unit))
    end
  in
  (module struct
    let name = name
    let backend = backend
    let readable = None

    (* Nothing reads the journal or cursor from a target reads never reach, so
       carrying them would be dead weight. {!Readable} says otherwise. *)
    let skip key =
      String.starts_with ~prefix:journal_prefix key || key = cursor_key

    let stats () =
      let s = Q.stats queue in
      {
        queued = s.Durable_queue.queued;
        in_flight = !chunks_in_flight;
        degraded = s.Durable_queue.degraded;
      }

    let accept = function
      | Put { key; data } when String.starts_with ~prefix:chunk_prefix key ->
          forward_chunk key data;
          Lwt.return_unit
      | Put { key; _ } -> Q.post queue (Job_put key)
      | Copy { src_key; dst_key } -> Q.post queue (Job_copy (src_key, dst_key))
      | Delete key -> Q.post queue (Job_delete key)
      | Delete_multi keys -> Q.post queue (Job_delete_multi keys)
  end)

module Readable (D : S) : S = struct
  include D

  let readable = Some D.backend
  let skip _ = false
end
