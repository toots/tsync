include Backend_intf
module Watch_token = Watch_token

let default_watch_interval = 2.

exception Backend_error of string
exception Not_writable

(* Both spellings, from both stores, in one list: a driver deciding this for
   itself is how two of them came to disagree about what a bulk delete reporting
   a missing key means. *)
let absent_code = function "NoSuchKey" | "NotFound" -> true | _ -> false

let checked_range ~op ~key ~length body =
  if Bigstring.length body > length then
    raise
      (Backend_error
         (Printf.sprintf "%s get_range %s: asked for %d bytes, got %d" op key
            length (Bigstring.length body)))
  else body

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

(* Runs a request may ask for at once. Both bounds are needed: the count is what
   a request line carries, and the byte budget is what the answer costs in
   memory, which a folder of large manifests reaches first. *)
let max_batch_keys = 256
let max_batch_bytes = 8 * 1024 * 1024

(* Folders one {!S.list_many} request may name. *)
let max_batch_folders = 64

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

(* One store's own share of what {!Metrics} counts globally. Separate counters
   rather than a total each, so a rate comes off the same ring the process-wide
   figures do and nothing reimplements the window. *)
type traffic = Metrics.traffic = {
  uploaded : Metrics.counter;
  downloaded : Metrics.counter;
}

let new_traffic = Metrics.traffic

type role = [ `Main | `Replica | `Backfill | `ReadOnly ]

type 'store member = {
  name : string;
  role : role;
  readable : bool;
  backend_type : string;  (** local | s3 | gcs | http-proxy *)
  config : (string * string) list;
      (** What this store points at — a bucket, a URL, a path — with secret
          fields masked: a report gets pasted into bug threads. *)
  backend : 'store;  (** The leaf store, so a reader can probe it directly. *)
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

let main members = List.find_opt (fun m -> m.role = `Main) members

let link_json m =
  (match m.traffic with
    | None -> []
    | Some t -> [("traffic", `Assoc (Metrics.traffic_fields t))])
  @
    match (m.pending, m.in_flight, m.degraded) with
    | Some queued, Some in_flight, Some degraded ->
        [
          ( "deferred",
            `Assoc
              [
                ("queued", `Int (queued ()));
                ("inFlight", `Int (in_flight ()));
                ("degraded", `Bool (degraded ()));
              ] );
        ]
    | _ -> []

let deferred members =
  List.filter (fun m -> m.role = `Replica || m.role = `Backfill) members

let named name members = List.find_opt (fun m -> m.name = name) members

let named_exn name members =
  match List.filter (fun m -> m.name = name) members with
    | [m] -> m
    | [] ->
        failwith
          (Printf.sprintf "no backend named %s (available: %s)" name
             (String.concat ", " (List.map (fun m -> m.name) members)))
    | _ ->
        failwith
          (Printf.sprintf
             "backend name %s is ambiguous; set distinct \"name\" fields in \
              the config"
             name)

(* What the batched reads need of a pool. *)

(* The registries here are one per process: the drivers that register
   themselves, the hooks a composite settles through, and the pool the batched
   reads come out of. So this is applied once, in the layer that names a
   scheduler. *)
module Make (Io : Io.S) (Bounded : Bounded.S with type 'a io := 'a Io.t) =
struct
  module type Store = S with type 'a io := 'a Io.t

  open Io_syntax.Make (Io)

  (* Object reads a batch stands in for, for a caller with no budget of its own.
     Module-level, since a pool built per call is not a bound. *)
  let batch_slots = lazy (Bounded.create ~name:"batch reads" ~max:32 ())

  module Batched (B : Store) = struct
    (* The pool is taken once on either path: a run under a slot, or a key under
       a slot, never a run holding one while its keys wait for theirs. *)
    let get_many ?slots ~entries () =
      let slots =
        match slots with Some s -> s | None -> Lazy.force batch_slots
      in
      match B.get_many with
        | Some f ->
            let+ answered =
              Bounded.map_with slots
                (fun run -> f ~entries:run ())
                (batches entries)
            in
            List.concat answered
        | None ->
            Bounded.map_with slots
              (fun (e : file_entry) ->
                let+ body = B.get_opt ~key:e.key () in
                (e.key, body))
              entries
  end

  type factory = (string -> string option) -> (module Store)

  let drain_hooks : (unit -> unit Io.t) list ref = ref []
  let on_drain f = drain_hooks := f :: !drain_hooks
  let drain () = Io.iter_p (fun f -> f ()) !drain_hooks

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
    let module Inner = (val m : Store) in
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

      let get_range ~key ~offset ~length () =
        let+ data = Inner.get_range ~key ~offset ~length () in
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

      let list_many =
        Option.map
          (fun f ~prefixes () ->
            let+ answered = f ~prefixes () in
            List.iter
              (fun (_, c) ->
                List.iter
                  (fun (_, body) ->
                    Option.iter (fun b -> down (Bigstring.length b)) body)
                  c.bodies)
              answered;
            answered)
          Inner.list_many
    end : Store)

  let make ?traffic ~backend_type ~get_field () =
    match Hashtbl.find_opt registry backend_type with
      | Some { factory; _ } ->
          let store = factory get_field in
          let module St = (val store : Store) in
          (* A store that is a tree here read nothing over a link, so there is no
             traffic to count. Derived from the store rather than asked of its
             type, so the wrapper that counts and the report that prints cannot
             disagree about which stores have a figure. *)
          if St.local_path <> None then store
          else
            counted
              ~traffic:
                (match traffic with Some t -> t | None -> new_traffic ())
              store
      | None -> failwith ("unknown backend type: " ^ backend_type)
end
