type file_entry = {
  key : string;
  size : int;
  last_modified : float;
  content_type : string option;
}

exception Backend_error of string
exception Cancelled

module type S = sig
  val put : ?content_type:string -> key:string -> data:string -> unit -> unit
  val get : key:string -> unit -> string
  val head_opt : key:string -> unit -> file_entry option
  val delete : key:string -> unit -> unit
  val delete_multi : string list -> unit
  val copy : src_key:string -> dst_key:string -> unit -> unit
  val list_all : prefix:string -> unit -> file_entry list
  val list_directory : prefix:string -> unit -> file_entry list * string list
end

type factory = (string -> string option) -> (module S)

let registry : (string, factory) Hashtbl.t = Hashtbl.create 4
let register name (f : factory) = Hashtbl.replace registry name f

let make ~backend_type ~get_field =
  match Hashtbl.find_opt registry backend_type with
    | Some f -> f get_field
    | None -> failwith ("unknown backend type: " ^ backend_type)
