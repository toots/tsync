module type POOLS = sig
  type 'a io
  type t

  val use : t -> (unit -> 'a io) -> 'a io
end

module Over (Io : Io.S) (Pools : POOLS with type 'a io := 'a Io.t) = struct
  module Memo = Dedup.Over (Io)

  module type DEPS = sig
    val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit Io.t
    val backend_key : string -> Stored_key.t
    val present : string -> bool Io.t
    val fetch_body : string -> Bigstring.t Io.t

    val fetch_body_range :
      string -> offset:int -> length:int -> Bigstring.t Io.t
    val corrupt : string -> bool Io.t
    val cleared : string -> unit
    val slots : Pools.t
    val downloads : Pools.t
    val max_known : unit -> int
  end

  module Make (D : DEPS) = struct
    let ( let* ) = Io.bind
    let ( let+ ) x f = Io.map f x

    (* Not pre-populated by listing the chunk prefix: that cost scales with the
       whole historical archive rather than the upload at hand. *)
    let dedup = Dedup.create ~max_known:D.max_known ()
    let known_count () = Dedup.count dedup

    (* [data] must own its bytes: a store is free to keep sending after this
       returns, and the key is the hash of what was passed, not of what lands. *)
    let put data =
      let key = Chunks.key_of_body data in
      Metrics.add_hashed 1;
      let* known = Memo.known dedup ~corrupt:D.corrupt ~present:D.present key in
      let+ () =
        if known then (
          Dedup.remember dedup key;
          Io.return ())
        else
          let+ () = D.put ~key:(D.backend_key key) ~data () in
          D.cleared key;
          Dedup.remember dedup key
      in
      (key, not known)

    let store = function
      | Chunk_source.Stored key -> Io.return (key, false)
      | Mapped bytes -> Pools.use D.slots (fun () -> put (bytes ()))
      | Filled { len; fill } ->
          Pools.use D.slots (fun () ->
              let buf = Bigstring.create len in
              let* () = fill buf in
              put buf)

    let fetch key = Pools.use D.downloads (fun () -> D.fetch_body key)

    let fetch_range key ~offset ~length =
      Pools.use D.downloads (fun () -> D.fetch_body_range key ~offset ~length)
  end
end
