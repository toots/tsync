(* The shell an object store presents through {!Backend.S}: the verbs rendered
   to string keys, and everything a bucket answers the same way whoever runs
   it. A verify and a discard are queued as job bodies for the function the
   bucket was deployed with; there is no native batch, no local path, and a
   watch is the sleep a caller would otherwise spell itself. *)

module type VERBS = sig
  type 'a io
  type t

  val put : t -> key:string -> data:Bigstring.t -> unit -> unit io

  val put_if_absent :
    t -> key:string -> data:Bigstring.t -> unit -> Bigstring.t io

  val get : t -> key:string -> unit -> Bigstring.t io
  val get_opt : t -> key:string -> unit -> Bigstring.t option io

  val get_range :
    t -> key:string -> offset:int -> length:int -> unit -> Bigstring.t option io

  val head_opt : t -> key:string -> unit -> Backend.file_entry option io
  val delete : t -> key:string -> unit -> unit io
  val delete_multi : t -> string list -> unit io
  val copy : t -> src_key:string -> dst_key:string -> unit -> unit io

  val list_all :
    t -> ?max_keys:int -> prefix:string -> unit -> Backend.file_entry list io

  (* The job bodies the verifier and the discard write are text. *)
  val put_text : t -> key:string -> data:string -> unit -> unit io
  val share_url : t -> string option
end

module Over
    (Io : Io.S)
    (Bounded : Bounded.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (V : VERBS with type 'a io := 'a Io.t) =
struct
  module Verify = Verifier.Over (Io) (Bounded)

  module type Store = Backend.S with type 'a io := 'a Io.t

  let ( let+ ) x f = Io.map f x

  let make (t : V.t) : (module Store) =
    let str = Stored_key.to_string in
    let put_text ~key ~data () = V.put_text t ~key:(str key) ~data () in
    (module struct
      let put ~key ~data () = V.put t ~key:(str key) ~data ()

      let put_if_absent ~key ~data () =
        V.put_if_absent t ~key:(str key) ~data ()

      let get ~key () = V.get t ~key:(str key) ()
      let get_opt ~key () = V.get_opt t ~key:(str key) ()
      let fast_read = false

      let get_range ~key ~offset ~length () =
        V.get_range t ~key:(str key) ~offset ~length ()

      let head_opt ~key () = V.head_opt t ~key:(str key) ()
      let delete ~key () = V.delete t ~key:(str key) ()
      let delete_multi keys = V.delete_multi t (List.map str keys)

      let copy ~src_key ~dst_key () =
        V.copy t ~src_key:(str src_key) ~dst_key:(str dst_key) ()

      let list_prefix ?max_keys ~prefix () = V.list_all t ?max_keys ~prefix ()
      let get_many = None
      let list_many = None

      let verify_all ~chunk_prefix () =
        let+ n =
          Verify.queue
            ~on_progress:(fun ~done_ ~total ->
              if done_ mod 256 = 0 || done_ = total then
                Log.info "verify: queued %d/%d shard request(s)" done_ total)
            ~put:put_text ~chunk_prefix ()
        in
        `Queued n

      (* Taken as given, as [verified] is and for the same reason: the function
         that consumes these is deployed by the terraform that makes the bucket,
         and a deployment half applied is not a state this reports its way out
         of. A request nothing picks up is reported by [tsync gc --status] and
         re-delivered by [tsync gc --retry-jobs]. *)
      let discard ~chunk_prefix ~run ~name ~keys () =
        let+ () =
          Discard_job.queue ~put:put_text ~chunk_prefix ~run ~name ~keys ()
        in
        `Queued

      (* No chunk size or concurrency opinion: an object store is limited by the
         network and its own concurrency, neither measurable from here. *)
      let capabilities ~prefix:_ () =
        Io.return
          { Backend.no_caps with share_url = V.share_url t; verified = true }

      let watch ~key:_ ~last_seen:_ () =
        Clock.sleep Backend.default_watch_interval

      let local_path = None
    end)
end
