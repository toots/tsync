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
  let list_many = None
  let fast_read = false
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
  let list_many = None
  let fast_read = false
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let local_path = None
end

module Outage (Real : Backend_lwt.Store) = struct
  include Real

  let up = ref true
  let returned = Lwt_condition.create ()
  let count = ref 0

  let set_up b =
    up := b;
    if b then Lwt_condition.broadcast returned ()

  let calls () = !count
  let reset () = count := 0

  (* Counted on entry, so a request stalled by the outage is one the caller made
     all the same. *)
  let gate f =
    incr count;
    let rec wait () =
      if !up then f () else Lwt.bind (Lwt_condition.wait returned) wait
    in
    wait ()

  let put ~key ~data () = gate (fun () -> Real.put ~key ~data ())

  let put_if_absent ~key ~data () =
    gate (fun () -> Real.put_if_absent ~key ~data ())

  let get ~key () = gate (fun () -> Real.get ~key ())
  let get_opt ~key () = gate (fun () -> Real.get_opt ~key ())

  let get_range ~key ~offset ~length () =
    gate (fun () -> Real.get_range ~key ~offset ~length ())

  let head_opt ~key () = gate (fun () -> Real.head_opt ~key ())
  let delete ~key () = gate (fun () -> Real.delete ~key ())
  let delete_multi keys = gate (fun () -> Real.delete_multi keys)

  let copy ~src_key ~dst_key () =
    gate (fun () -> Real.copy ~src_key ~dst_key ())

  let list_prefix ?max_keys ~prefix () =
    gate (fun () -> Real.list_prefix ?max_keys ~prefix ())

  let watch ~key ~last_seen () = gate (fun () -> Real.watch ~key ~last_seen ())

  (* Declared absent rather than inherited: a native batch passed through from
     [Real] would answer while the link is down. *)
  let get_many = None
  let list_many = None
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
  let list_many = None
  let fast_read = false
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
