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

let with_key_encoding (module B : S) : (module S) =
  (module struct
    let put ~key ~data () = B.put ~key:(Fs_util.encode_key key) ~data ()
    let get ~key () = B.get ~key:(Fs_util.encode_key key) ()

    let head_opt ~key () =
      let open Lwt.Syntax in
      let+ entry = B.head_opt ~key:(Fs_util.encode_key key) () in
      Option.map (fun e -> { e with key }) entry

    let delete ~key () = B.delete ~key:(Fs_util.encode_key key) ()
    let delete_multi keys = B.delete_multi (List.map Fs_util.encode_key keys)

    let copy ~src_key ~dst_key () =
      B.copy
        ~src_key:(Fs_util.encode_key src_key)
        ~dst_key:(Fs_util.encode_key dst_key)
        ()

    let list_all ~prefix () =
      let open Lwt.Syntax in
      let+ entries = B.list_all ~prefix:(Fs_util.encode_key prefix) () in
      List.map (fun e -> { e with key = Fs_util.decode_key e.key }) entries

    let list_directory ~prefix () =
      let open Lwt.Syntax in
      let+ files, dirs =
        B.list_directory ~prefix:(Fs_util.encode_key prefix) ()
      in
      ( List.map (fun e -> { e with key = Fs_util.decode_key e.key }) files,
        List.map Fs_util.decode_component dirs )
  end)

let make ~backend_type ~get_field =
  match Hashtbl.find_opt registry backend_type with
    | Some f -> with_key_encoding (f get_field)
    | None -> failwith ("unknown backend type: " ^ backend_type)
