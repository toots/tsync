(** Client identity and folder-id leases (spec 03 §2.1): one uuid per data
    directory, shared by every domain and process; folder ids minted from leased
    blocks of 1024 counters, never contacting a store or another process. *)

open Tsync_core

(** [<data_dir>/client-uuid], created race-free on first use. *)
val client_uuid : string -> string

type minter

val minter : data_dir:string -> uuid:string -> minter

(** A fresh folder id [<first 12 hex of the uuid>-<counter hex>]. *)
val mint : minter -> Folder_id.t
