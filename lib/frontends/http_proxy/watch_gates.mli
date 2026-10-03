(** Watch coalescing (spec frontends/http-proxy.md §A7): many clients waiting on
    one key cost the store one watch, which runs only while someone waits. *)

open Tsync_core

type t

val create : unit -> t

(** Holds until the key's token differs from [last_seen] ([`Changed]) or [wait]
    seconds pass ([`Unchanged]); the key is read on arrival. *)
val wait :
  t ->
  route:string ->
  store:Tsync_store.Store.t ->
  Key.t ->
  last_seen:string option ->
  wait:float ->
  [ `Changed | `Unchanged ]
