type file_entry = { key : string; size : int; last_modified : float }

exception Backend_error of string
exception Cancelled

module type S = sig
  val put : key:string -> data:string -> unit -> unit Lwt.t
  val get : key:string -> unit -> string Lwt.t
  val head_opt : key:string -> unit -> file_entry option Lwt.t
  val delete : key:string -> unit -> unit Lwt.t
  val delete_multi : string list -> unit Lwt.t
  val copy : src_key:string -> dst_key:string -> unit -> unit Lwt.t
  val list_all : prefix:string -> unit -> file_entry list Lwt.t

  val list_directory :
    prefix:string -> unit -> (file_entry list * string list) Lwt.t
end

type factory = (string -> string option) -> (module S)

let registry : (string, factory) Hashtbl.t = Hashtbl.create 4
let register name (f : factory) = Hashtbl.replace registry name f

let make ~backend_type ~get_field =
  match Hashtbl.find_opt registry backend_type with
    | Some f -> f get_field
    | None -> failwith ("unknown backend type: " ^ backend_type)
