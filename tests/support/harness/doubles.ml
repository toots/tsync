module Down (M : sig
  val why : string
end) : Backend_lwt.Store = struct
  let fail () = Lwt.fail (Backend.Backend_error M.why)
  let put ~key:_ ~data:_ () = fail ()
  let put_if_absent ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let get_range ~key:_ ~offset:_ ~length:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
  let watch ~key:_ ~last_seen:_ () = fail ()
  let get_many = None
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let local_path = None
end

module Hung : Backend_lwt.Store = struct
  let never () = fst (Lwt.wait ())
  let put ~key:_ ~data:_ () = never ()
  let put_if_absent ~key:_ ~data:_ () = never ()
  let get ~key:_ () = never ()
  let get_opt ~key:_ () = never ()
  let get_range ~key:_ ~offset:_ ~length:_ () = never ()
  let head_opt ~key:_ () = never ()
  let delete ~key:_ () = never ()
  let delete_multi _ = never ()
  let copy ~src_key:_ ~dst_key:_ () = never ()
  let list_prefix ?max_keys:_ ~prefix:_ () = never ()
  let watch ~key:_ ~last_seen:_ () = never ()
  let get_many = None
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let local_path = None
end

module Refuses : Backend_lwt.Store = struct
  let fail () = Lwt.fail Backend.Not_writable
  let put ~key:_ ~data:_ () = fail ()
  let put_if_absent ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let get_range ~key:_ ~offset:_ ~length:_ () = fail ()
  let head_opt ~key:_ () = Lwt.return_none
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = Lwt.return_nil
  let watch ~key:_ ~last_seen:_ () = Lwt.return_unit
  let get_many = None
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let local_path = None
end

(* What a store answers a range read with, for a double holding whole bodies.
   Clamped at the end of the object as every driver's is, so a double cannot
   answer a range a real store would have cut short. *)
let range_of ~offset ~length body =
  Bigstring.sub body ~off:offset
    ~len:(max 0 (min length (Bigstring.length body - offset)))
