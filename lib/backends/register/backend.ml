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
  val list_all : ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  val list_directory :
    prefix:string ->
    unit ->
    (file_entry list * (string * float option) list) Lwt.t
end

type factory = (string -> string option) -> (module S)
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
