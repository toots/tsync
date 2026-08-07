type file_entry = { key : string; size : int; last_modified : float }

exception Backend_error of string
exception Cancelled

(* Its own exception rather than a [Backend_error] carrying a sentence, because
   callers act on it: a frontend turns it into a read-only error for the user,
   and matching on prose breaks the day the sentence is reworded. *)
exception Not_writable

(* Whether a failure is worth trying again, decided by the store that produced
   it — one vocabulary rather than each backend's own notion of "transient" and
   each caller having to recognise it. A 503, a dropped socket and a full disk
   clear on their own; a 403, a bad key and a read-only domain do not, and
   retrying those only delays the report. *)
type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }

let failed ~kind ~op detail = Failed { kind; op; detail }

let string_of_kind = function
  | Transient -> "transient"
  | Permanent -> "permanent"

(* [Transient] for anything unrecognised: a failure mode nobody classified is
   retried rather than silently abandoning the work. *)
let classify = function
  | Failed { kind; _ } -> kind
  | Not_writable -> Permanent
  (* A store's considered answer — a missing chunk, a truncated body — not a
     hiccup. *)
  | Backend_error _ -> Permanent
  | _ -> Transient

(* What to put in a log line: [Printexc] would repeat the operation name the
   caller has already printed. *)
let reason = function
  | Failed { detail; _ } -> detail
  | exn -> Printexc.to_string exn

let () =
  Printexc.register_printer (function
    | Not_writable ->
        Some "no writable backend: every backend in this domain is \"readOnly\""
    | Failed { kind; op; detail } ->
        Some (Printf.sprintf "%s: %s (%s)" op detail (string_of_kind kind))
    | _ -> None)

(* The one retry loop. A backend decides only what [Transient] means for it; the
   backoff, the cap and the log line are shared, so two stores cannot drift into
   retrying differently. [Cancelled] is never retried. *)
let default_attempts = 8

let with_retry ?(max_attempts = default_attempts) ~name ~op f =
  let rec go attempt =
    Lwt.catch f (function
      | Cancelled as exn -> Lwt.fail exn
      | exn when attempt < max_attempts && classify exn = Transient ->
          let backoff =
            Float.min 20. (0.5 *. (2. ** float_of_int (attempt - 1)))
          in
          let delay = backoff *. (0.5 +. Random.float 1.0) in
          Log.warn "%s %s: %s; retrying (%d/%d) in %.1fs" name op (reason exn)
            attempt max_attempts delay;
          Lwt.bind (Lwt_unix.sleep delay) (fun () -> go (attempt + 1))
      | exn -> Lwt.fail exn)
  in
  go 1

module type S = sig
  val put : key:string -> data:string -> unit -> unit Lwt.t
  val get : key:string -> unit -> string Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:string -> unit -> string option Lwt.t

  val head_opt : key:string -> unit -> file_entry option Lwt.t
  val delete : key:string -> unit -> unit Lwt.t
  val delete_multi : string list -> unit Lwt.t
  val copy : src_key:string -> dst_key:string -> unit -> unit Lwt.t

  val list_prefix :
    ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  (** The share base URL if this backend serves shares for [prefix]'s domain,
      else [None]. s3 returns its configured [shareUrl]; http-proxy asks the
      frontend; others return [None]. [prefix] identifies the domain for
      backends (like http-proxy) that front several. *)
  val share_url : prefix:string -> unit -> string option Lwt.t

  (** The chunk size this backend recommends for new files in [prefix]'s domain,
      or [None] if it has no opinion (which is every store that only holds
      bytes). An http-proxy answers with the serving domain's own [chunkSize],
      so a client behind one inherits it instead of mirroring the setting in two
      configs. Only consulted when the client's own config does not say. *)
  val default_chunk_size : prefix:string -> unit -> int option Lwt.t

  (** How many object reads or writes this backend can usefully serve at once,
      or [None] with no opinion — every store whose limit is the network rather
      than a measurable device.

      Asked by frontends accepting work from many clients, so they can hold
      requests instead of handing them all to storage. A local store answers
      from the device under it; an http-proxy asks its peer, so a client
      inherits the real limit rather than guessing at hardware it cannot see. *)
  val max_concurrency : prefix:string -> unit -> int option Lwt.t
end

type factory = (string -> string option) -> (module S)

(* A composite finishing work in the background registers here, so a process
   about to exit can let it settle without knowing which composites are in play.
   A one-shot command would otherwise take the pending work with it. *)
let drain_hooks : (unit -> unit Lwt.t) list ref = ref []
let on_drain f = drain_hooks := f :: !drain_hooks
let drain () = Lwt_list.iter_p (fun f -> f ()) !drain_hooks

(* A domain's backends individually. The composites ({!Fallback}, {!Lane})
   present one {!S} and keep their members' names to themselves, so whoever builds
   a domain's backends declares them here rather than each composite growing an
   introspection interface. Only diagnosis reads this; nothing routes on it. *)
type member = {
  name : string;
  role : string;  (** main | replica | backfill | readOnly *)
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
  degraded : (unit -> bool) option;
      (** Replica and backfill: writes were dropped, [tsync resync-remote] is
          needed — unlike a target merely being behind, patience will not fix
          this. *)
  local_path : string option;
      (** Where a [local] store keeps its files, so a report can say how much
          room is left. Absent for stores whose capacity is not ours to know. *)
}

let member_registry : (string, member list) Hashtbl.t = Hashtbl.create 4
let report_members ~domain ms = Hashtbl.replace member_registry domain ms

let members ~domain =
  Option.value ~default:[] (Hashtbl.find_opt member_registry domain)

type field_type = [ `String | `Bool ]

type field_spec = {
  name : string;
  label : string;
  typ : field_type;
  default : string option;
      (** [None] is required; [Some ""] optional, omitted from JSON when blank;
          [Some s] optional with default [s]. *)
  secret : bool;
}

type entry = { factory : factory; spec : field_spec list }

let registry : (string, entry) Hashtbl.t = Hashtbl.create 4

let register ~spec name (f : factory) =
  Hashtbl.replace registry name { factory = f; spec }

let spec_for name =
  Option.map (fun e -> e.spec) (Hashtbl.find_opt registry name)

(* Every registered type name, for a UI offering a choice. What is available
   depends on how the binary was linked, since s3 is optional. *)
let types () =
  List.sort compare (Hashtbl.fold (fun name _ acc -> name :: acc) registry [])

let make ~backend_type ~get_field =
  match Hashtbl.find_opt registry backend_type with
    | Some { factory; _ } -> factory get_field
    | None -> failwith ("unknown backend type: " ^ backend_type)
