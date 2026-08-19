type file_entry = { key : string; size : int; last_modified : float }

exception Backend_error of string
exception Cancelled
exception Not_writable

type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }

let failed ~kind ~op detail = Failed { kind; op; detail }

let string_of_kind = function
  | Transient -> "transient"
  | Permanent -> "permanent"

(* Both spellings, from both stores, in one list: a driver deciding this for
   itself is how two of them came to disagree about what a bulk delete reporting
   a missing key means. *)
let absent_code = function "NoSuchKey" | "NotFound" -> true | _ -> false

let classify = function
  | Failed { kind; _ } -> kind
  | Not_writable -> Permanent
  (* A store's considered answer — a missing chunk, a truncated body — not a
     hiccup. *)
  | Backend_error _ -> Permanent
  | _ -> Transient

let reason = function
  | Failed { detail; _ } -> detail
  | exn -> Printexc.to_string exn

(* These reach users verbatim through [Printexc.to_string], whose default
   printer spells an exception with its full module path — the internal library
   name, for a wrapped library — so every case is spelled out here. *)
let () =
  Printexc.register_printer (function
    | Not_writable ->
        Some "no writable backend: every backend in this domain is \"readOnly\""
    | Failed { kind; op; detail } ->
        Some (Printf.sprintf "%s: %s (%s)" op detail (string_of_kind kind))
    | Backend_error msg -> Some (Printf.sprintf "Backend.Backend_error(%S)" msg)
    | Cancelled -> Some "Backend.Cancelled"
    | _ -> None)

let default_attempts = 8

let backoff ~base ~cap attempt =
  Float.min cap (base *. (2. ** float_of_int (min 10 (attempt - 1))))

let with_retry ?(max_attempts = default_attempts) ~name ~op f =
  let rec go attempt =
    Lwt.catch f (function
      | Cancelled as exn -> Lwt.fail exn
      | exn when attempt < max_attempts && classify exn = Transient ->
          let delay =
            backoff ~base:0.5 ~cap:20. attempt *. (0.5 +. Random.float 1.0)
          in
          (* Timeouts are counted apart from the retries they are part of: a
             link that answers slowly and one that stops answering are the same
             number of retries and very different problems. *)
          Metrics.add_retry 1;
          if exn = Lwt_unix.Timeout then Metrics.add_timeout 1;
          Log.warn "%s %s: %s; retrying (%d/%d) in %.1fs" name op (reason exn)
            attempt max_attempts delay;
          Lwt.bind (Lwt_unix.sleep delay) (fun () -> go (attempt + 1))
      | exn ->
          Metrics.add_failure 1;
          Lwt.fail exn)
  in
  go 1

type caps = {
  share_url : string option;
  chunk_size : int option;
  max_concurrency : int option;
  gc : bool;
  verified : bool;
}

let no_caps =
  {
    share_url = None;
    chunk_size = None;
    max_concurrency = None;
    gc = false;
    verified = false;
  }

let merge_caps cs =
  let first a b = match a with Some _ -> a | None -> b in
  let lowest a b =
    match (a, b) with
      | Some a, Some b -> Some (min a b)
      | None, some | some, None -> some
  in
  let merged =
    List.fold_left
      (fun acc c ->
        {
          share_url = first acc.share_url c.share_url;
          chunk_size = first acc.chunk_size c.chunk_size;
          max_concurrency = lowest acc.max_concurrency c.max_concurrency;
          gc = acc.gc || c.gc;
          verified = acc.verified;
        })
      no_caps cs
  in
  (* Every store, where {!caps.gc} takes any: gc describes machinery one store
     either has or does not, while this is a claim about the domain's bytes, and
     one unchecked store is enough to make "no corruption found" mean "nothing
     looked". Empty is nobody's claim, so it is not one either. *)
  { merged with verified = cs <> [] && List.for_all (fun c -> c.verified) cs }

module type S = sig
  val put : key:string -> data:Chunk.t -> unit -> unit Lwt.t
  val get : key:string -> unit -> Chunk.t Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:string -> unit -> Chunk.t option Lwt.t

  val put_if_absent : key:string -> data:Chunk.t -> unit -> Chunk.t Lwt.t
  val head_opt : key:string -> unit -> file_entry option Lwt.t
  val delete : key:string -> unit -> unit Lwt.t
  val delete_multi : string list -> unit Lwt.t
  val copy : src_key:string -> dst_key:string -> unit -> unit Lwt.t

  val list_prefix :
    ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  val verify_all :
    chunk_prefix:string -> unit -> [ `Queued of int | `Unsupported ] Lwt.t

  val discard :
    chunk_prefix:string ->
    run:string ->
    name:string ->
    keys:string list ->
    unit ->
    [ `Queued | `Unsupported ] Lwt.t

  (** What this store can tell a client about [prefix]'s domain beyond holding
      its bytes. See {!caps}; [no_caps] is the honest answer for every store
      that only holds bytes. *)
  val capabilities : prefix:string -> unit -> caps Lwt.t
end

type factory = (string -> string option) -> (module S)

let drain_hooks : (unit -> unit Lwt.t) list ref = ref []
let on_drain f = drain_hooks := f :: !drain_hooks
let drain () = Lwt_list.iter_p (fun f -> f ()) !drain_hooks

(* One store's own share of what {!Metrics} counts globally. Separate counters
   rather than a total each, so a rate comes off the same ring the process-wide
   figures do and nothing reimplements the window. *)
type traffic = { uploaded : Metrics.counter; downloaded : Metrics.counter }

let new_traffic () =
  { uploaded = Metrics.counter (); downloaded = Metrics.counter () }

(* A local store is a filesystem, so nothing it reads or writes crossed a link.
   Asked here by both the wrapper that counts and the caller that decides
   whether a store has a figure worth reporting, so the two cannot drift into
   disagreeing about which stores have traffic. *)
let counts_traffic ~backend_type = backend_type <> "local"

type member = {
  name : string;
  role : string;  (** main | replica | backfill | readOnly *)
  readable : bool;
  backend_type : string;  (** local | s3 | gcs | http-proxy *)
  config : (string * string) list;
      (** What this store points at — a bucket, a URL, a path — with secret
          fields masked: a report gets pasted into bug threads. *)
  backend : (module S);
      (** The leaf store, so a reader can probe it directly. *)
  pending : (unit -> int) option;
      (** Replica and backfill: jobs this target still owes, kept on disk. *)
  in_flight : (unit -> int) option;
      (** Replica and backfill: chunk forwards in flight. *)
  traffic : traffic option;
      (** What crossed the link to this store, for the stores that have a link:
          absent for a [local] one, which {!counts_traffic} excludes. *)
  degraded : (unit -> bool) option;
      (** Replica and backfill: writes were dropped, [tsync mirror] is needed —
          unlike a target merely being behind, patience will not fix this. *)
  local_path : string option;
      (** Where a [local] store keeps its files, so a report can say how much
          room is left. Absent for stores whose capacity is not ours to know. *)
}

let member ?(role = "main") ?(readable = true) ?(backend_type = "local")
    ?(config = []) ?local_path ?pending ?in_flight ?degraded ?traffic ~name
    backend =
  {
    name;
    role;
    readable;
    backend_type;
    config;
    backend;
    pending;
    in_flight;
    degraded;
    traffic;
    local_path;
  }

type entry = { factory : factory; spec : Field_spec.t list }

let registry : (string, entry) Hashtbl.t = Hashtbl.create 4

let register ~spec name (f : factory) =
  Hashtbl.replace registry name { factory = f; spec }

let spec_for name =
  Option.map (fun e -> e.spec) (Hashtbl.find_opt registry name)

let types () =
  List.sort compare (Hashtbl.fold (fun name _ acc -> name :: acc) registry [])

(* Bytes are counted here rather than at the content layer, which is the only
   place that reached: a collection, a mirror and a repair go to a store
   directly, so the figure a report showed was the chunk path's traffic under a
   name that claimed to be the backend's.

   Only the verbs that carry a body, and only where a body crosses a link: a
   local store is a filesystem, and counting its reads as traffic would bury the
   remote ones it exists to be read instead of. *)
let counted ~traffic m =
  let module Inner = (val m : S) in
  (* Every body is counted twice over: once for the process, once for the store
     it went to. The per-store figure is what says which link a stalled transfer
     is stalled on, which the sum cannot. *)
  let up n =
    Metrics.add_uploaded n;
    Metrics.count traffic.uploaded n
  and down n =
    Metrics.add_downloaded n;
    Metrics.count traffic.downloaded n
  in
  (module struct
    open Lwt.Syntax
    include Inner

    let put ~key ~data () =
      let+ () = Inner.put ~key ~data () in
      up (Chunk.length data)

    (* A loser gets the winning body back, which came down the link; the winner
       is handed its own [data] again, so physical identity tells them apart
       without comparing bodies that are equal by construction. *)
    let put_if_absent ~key ~data () =
      let+ held = Inner.put_if_absent ~key ~data () in
      up (Chunk.length data);
      if held != data then down (Chunk.length held);
      held

    let get ~key () =
      let+ data = Inner.get ~key () in
      down (Chunk.length data);
      data

    let get_opt ~key () =
      let+ data = Inner.get_opt ~key () in
      Option.iter (fun d -> down (Chunk.length d)) data;
      data
  end : S)

let make ?traffic ~backend_type ~get_field () =
  match Hashtbl.find_opt registry backend_type with
    | Some { factory; _ } ->
        let store = factory get_field in
        if not (counts_traffic ~backend_type) then store
        else
          counted
            ~traffic:(match traffic with Some t -> t | None -> new_traffic ())
            store
    | None -> failwith ("unknown backend type: " ^ backend_type)
