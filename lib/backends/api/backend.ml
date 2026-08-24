type file_entry = {
  key : Stored_key.t;
  size : int;
  last_modified : float;
  etag : string option;
      (** What the store calls this object's version, when it has a name for
          one: an S3 or GCS listing carries it, a filesystem has none.

          The only validator worth caching an object's body against. Size and
          [last_modified] are not: S3 reports whole seconds, and a manifest
          rewritten inside one to a body of the same length — same name, same
          chunk count — is invisible in both. *)
}

exception Backend_error of string
exception Not_writable

(* Both spellings, from both stores, in one list: a driver deciding this for
   itself is how two of them came to disagree about what a bulk delete reporting
   a missing key means. *)
let absent_code = function "NoSuchKey" | "NotFound" -> true | _ -> false

(* The two a store answers for itself: a missing chunk or a truncated body is a
   considered answer, not a hiccup. Everything else is {!Retry}'s to judge. *)
let classify = function
  | Not_writable | Backend_error _ -> Retry.Permanent
  | exn -> Retry.classify exn

(* These reach users verbatim through [Printexc.to_string], whose default
   printer spells an exception with its full module path — the internal library
   name, for a wrapped library — so every case is spelled out here. *)
let () =
  Printexc.register_printer (function
    | Not_writable ->
        Some "no writable backend: every backend in this domain is \"readOnly\""
    | Backend_error msg -> Some (Printf.sprintf "Backend.Backend_error(%S)" msg)
    | _ -> None)

type caps = {
  share_url : string option;
  chunk_size : int option;
  max_concurrency : int option;
  verified : bool;
}

let no_caps =
  {
    share_url = None;
    chunk_size = None;
    max_concurrency = None;
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
          verified = acc.verified;
        })
      no_caps cs
  in
  (* Every store: this is a claim about the domain's bytes, and one unchecked
     store is enough to make "no corruption found" mean "nothing looked". Empty
     is nobody's claim, so it is not one either. *)
  { merged with verified = cs <> [] && List.for_all (fun c -> c.verified) cs }

module type S = sig
  val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit Lwt.t
  val get : key:Stored_key.t -> unit -> Bigstring.t Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:Stored_key.t -> unit -> Bigstring.t option Lwt.t

  val put_if_absent :
    key:Stored_key.t -> data:Bigstring.t -> unit -> Bigstring.t Lwt.t

  val head_opt : key:Stored_key.t -> unit -> file_entry option Lwt.t
  val delete : key:Stored_key.t -> unit -> unit Lwt.t
  val delete_multi : Stored_key.t list -> unit Lwt.t
  val copy : src_key:Stored_key.t -> dst_key:Stored_key.t -> unit -> unit Lwt.t

  val list_prefix :
    ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  (** A native multi-object read, or [None] from a store with none — which is
      every store but http-proxy, S3 having no multi-object GET and the GCS
      batch API carrying metadata only. Declared rather than implemented, so a
      store without one says so and {!Batched} supplies the fan-out. *)
  val get_many :
    (entries:file_entry list ->
    unit ->
    (Stored_key.t * Bigstring.t option) list Lwt.t)
    option

  val verify_all :
    chunk_prefix:string -> unit -> [ `Queued of int | `Unsupported ] Lwt.t

  val discard :
    chunk_prefix:string ->
    run:string ->
    name:string ->
    keys:Stored_key.t list ->
    unit ->
    [ `Queued | `Unsupported ] Lwt.t

  (** What this store can tell a client about [prefix]'s domain beyond holding
      its bytes. See {!caps}; [no_caps] is the honest answer for every store
      that only holds bytes. *)
  val capabilities : prefix:string -> unit -> caps Lwt.t

  val local_path : string option
end

(* Runs a request may ask for at once. Both bounds are needed: the count is what
   a request line carries, and the byte budget is what the answer costs in
   memory, which a folder of large manifests reaches first. *)
let max_batch_keys = 256
let max_batch_bytes = 8 * 1024 * 1024

let batches entries =
  let rec go done_ run keys bytes = function
    | [] -> List.rev (if run = [] then done_ else List.rev run :: done_)
    | e :: tl ->
        if
          run <> []
          && (keys >= max_batch_keys || bytes + e.size > max_batch_bytes)
        then go (List.rev run :: done_) [e] 1 e.size tl
        else go done_ (e :: run) (keys + 1) (bytes + e.size) tl
  in
  go [] [] 0 0 entries

(* Object reads a batch stands in for, for a caller with no budget of its own.
   Module-level, since a pool built per call is not a bound. *)
let batch_slots = lazy (Lwt_bounded.create ~name:"batch reads" ~max:32 ())

module Batched (B : S) = struct
  open Lwt.Syntax

  let get_many ?slots ~entries () =
    let slots =
      match slots with Some s -> s | None -> Lazy.force batch_slots
    in
    let ask run =
      match B.get_many with
        | Some f -> Lwt_bounded.use slots (fun () -> f ~entries:run ())
        | None ->
            Lwt_bounded.map_with slots
              (fun (e : file_entry) ->
                let+ body = B.get_opt ~key:e.key () in
                (e.key, body))
              run
    in
    (* A run at a time, so what is held is one request's bodies rather than the
       whole folder's twice over. *)
    let+ answered = Lwt_list.map_s ask (batches entries) in
    List.concat answered
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

type role = [ `Main | `Replica | `Backfill | `ReadOnly ]

type member = {
  name : string;
  role : role;
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
          absent for a store that is a tree here, having no link. *)
  degraded : (unit -> bool) option;
      (** Replica and backfill: writes were dropped, [tsync mirror] is needed —
          unlike a target merely being behind, patience will not fix this. *)
  local_path : string option;
      (** Where a [local] store keeps its files, so a report can say how much
          room is left. Absent for stores whose capacity is not ours to know. *)
}

let member ?(role = `Main) ?(readable = true) ?(backend_type = "local")
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
      up (Bigstring.length data)

    (* A loser gets the winning body back, which came down the link; the winner
       is handed its own [data] again, so physical identity tells them apart
       without comparing bodies that are equal by construction. *)
    let put_if_absent ~key ~data () =
      let+ held = Inner.put_if_absent ~key ~data () in
      up (Bigstring.length data);
      if held != data then down (Bigstring.length held);
      held

    let get ~key () =
      let+ data = Inner.get ~key () in
      down (Bigstring.length data);
      data

    let get_opt ~key () =
      let+ data = Inner.get_opt ~key () in
      Option.iter (fun d -> down (Bigstring.length d)) data;
      data

    (* The fan-out {!Batched} builds needs nothing here, going through the
       [get_opt] above; a store's own batch crosses the link unseen otherwise. *)
    let get_many =
      Option.map
        (fun f ~entries () ->
          let+ answered = f ~entries () in
          List.iter
            (fun (_, body) ->
              Option.iter (fun b -> down (Bigstring.length b)) body)
            answered;
          answered)
        Inner.get_many

    let local_path = Inner.local_path
  end : S)

let make ?traffic ~backend_type ~get_field () =
  match Hashtbl.find_opt registry backend_type with
    | Some { factory; _ } ->
        let store = factory get_field in
        let module St = (val store : S) in
        (* A store that is a tree here read nothing over a link, so there is no
           traffic to count. Derived from the store rather than asked of its
           type, so the wrapper that counts and the report that prints cannot
           disagree about which stores have a figure. *)
        if St.local_path <> None then store
        else
          counted
            ~traffic:(match traffic with Some t -> t | None -> new_traffic ())
            store
    | None -> failwith ("unknown backend type: " ^ backend_type)
