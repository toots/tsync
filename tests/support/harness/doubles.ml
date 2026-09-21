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
  let health = Health.always_up
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
  let health = Health.always_up
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

  (* Declared absent rather than inherited: a native batch or a path on this
     machine passed through from [Real] would answer while the link is down. *)
  let get_many = None
  let list_many = None
  let fast_read = false
  let local_path = None
  let health = Health.always_up
end

module Flaky (Real : Backend_lwt.Store) = struct
  include Real

  let owed : (string option * exn) list ref = ref []
  let refused = ref 0

  let refuse_next ?on
      ?(with_ = Retry.failed ~kind:Retry.Transient ~op:"link" "refused") n =
    owed := List.init n (fun _ -> (on, with_))

  let refusals () = !refused

  let gate name f =
    match !owed with
      | (on, exn) :: rest when Option.fold ~none:true ~some:(( = ) name) on ->
          owed := rest;
          incr refused;
          Lwt.fail exn
      | _ -> f ()

  let put ~key ~data () = gate "put" (fun () -> Real.put ~key ~data ())

  let put_if_absent ~key ~data () =
    gate "put_if_absent" (fun () -> Real.put_if_absent ~key ~data ())

  let get ~key () = gate "get" (fun () -> Real.get ~key ())
  let get_opt ~key () = gate "get_opt" (fun () -> Real.get_opt ~key ())

  let get_range ~key ~offset ~length () =
    gate "get_range" (fun () -> Real.get_range ~key ~offset ~length ())

  let head_opt ~key () = gate "head_opt" (fun () -> Real.head_opt ~key ())
  let delete ~key () = gate "delete" (fun () -> Real.delete ~key ())
  let delete_multi keys = gate "delete_multi" (fun () -> Real.delete_multi keys)

  let copy ~src_key ~dst_key () =
    gate "copy" (fun () -> Real.copy ~src_key ~dst_key ())

  let list_prefix ?max_keys ~prefix () =
    gate "list_prefix" (fun () -> Real.list_prefix ?max_keys ~prefix ())

  let get_many = None
  let list_many = None
  let fast_read = false
  let local_path = None
  let health = Health.always_up
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
  let health = Health.always_up
end

(* What a store answers a range read with, for a double holding whole bodies.
   Clamped at the end of the object as every driver's is, so a double cannot
   answer a range a real store would have cut short. *)
let range_of ~offset ~length body =
  Bigstring.sub body ~off:offset
    ~len:(max 0 (min length (Bigstring.length body - offset)))

module Memory () : Backend_lwt.Store = struct
  let objects : (Stored_key.t, Bigstring.t) Hashtbl.t = Hashtbl.create 8

  let put ~key ~data () =
    Hashtbl.replace objects key data;
    Lwt.return_unit

  (* The winner is handed back the very value it passed, which is what a real
     store does and what tells a win from a loss without comparing bodies. *)
  let put_if_absent ~key ~data () =
    match Hashtbl.find_opt objects key with
      | Some held -> Lwt.return held
      | None ->
          Hashtbl.replace objects key data;
          Lwt.return data

  let get_opt ~key () = Lwt.return (Hashtbl.find_opt objects key)

  let get_range ~key ~offset ~length () =
    Lwt.return
      (Option.map (range_of ~offset ~length) (Hashtbl.find_opt objects key))

  let get ~key () =
    match Hashtbl.find_opt objects key with
      | Some d -> Lwt.return d
      | None ->
          Lwt.fail
            (Backend.Backend_error ("no such key: " ^ Stored_key.to_string key))

  let head_opt ~key () =
    Lwt.return
      (Option.map
         (fun d ->
           {
             Backend.key;
             size = Bigstring.length d;
             last_modified = 0.;
             etag = None;
           })
         (Hashtbl.find_opt objects key))

  let delete ~key () =
    let held = Hashtbl.mem objects key in
    Hashtbl.remove objects key;
    Lwt.return held

  let delete_multi keys =
    List.iter (Hashtbl.remove objects) keys;
    Lwt.return_unit

  let copy ~src_key ~dst_key () =
    (match Hashtbl.find_opt objects src_key with
      | Some d -> Hashtbl.replace objects dst_key d
      | None -> ());
    Lwt.return_unit

  let list_prefix ?max_keys:_ ~prefix () =
    Lwt.return
      (Hashtbl.fold
         (fun key d acc ->
           if Stored_key.is_in ~prefix key then
             {
               Backend.key;
               size = Bigstring.length d;
               last_modified = 0.;
               etag = None;
             }
             :: acc
           else acc)
         objects [])

  let watch ~key:_ ~last_seen:_ () = Lwt.return_unit
  let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

  let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
    Lwt.return `Unsupported

  let get_many = None
  let list_many = None
  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  let fast_read = false
  let local_path = None
  let health = Health.always_up
end
