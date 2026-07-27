type file_entry = { key : string; size : int; last_modified : float }

exception Backend_error of string
exception Cancelled

module type S = sig
  val put : key:string -> data:string -> unit -> unit Lwt.t
  val get : key:string -> unit -> string Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted anyway. *)
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
end

type factory = (string -> string option) -> (module S)

(* A composite backend that finishes work in the background registers here, so a
   process about to exit can let it settle without knowing which composites are
   in play. A one-shot command would otherwise take the pending work with it. *)
let drain_hooks : (unit -> unit Lwt.t) list ref = ref []
let on_drain f = drain_hooks := f :: !drain_hooks
let drain () = Lwt_list.iter_p (fun f -> f ()) !drain_hooks

type field_type = [ `String | `Bool ]

type field_spec = {
  name : string;
  label : string;
  typ : field_type;
  default : string option;
      (** [None] = required; [Some ""] = optional, omit from JSON if blank;
          [Some s] = optional with default [s] *)
  secret : bool;
}

type entry = { factory : factory; spec : field_spec list }

let registry : (string, entry) Hashtbl.t = Hashtbl.create 4

let register ~spec name (f : factory) =
  Hashtbl.replace registry name { factory = f; spec }

let spec_for name =
  Option.map (fun e -> e.spec) (Hashtbl.find_opt registry name)

let make ~backend_type ~get_field =
  match Hashtbl.find_opt registry backend_type with
    | Some { factory; _ } -> factory get_field
    | None -> failwith ("unknown backend type: " ^ backend_type)
