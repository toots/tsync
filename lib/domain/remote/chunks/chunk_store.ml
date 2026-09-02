(* Chunk keys this session has seen present, bounded so it counts what the memo
   holds rather than what the session uploaded. *)
module Dedup = struct
  type t = { known : (string, unit) Hashtbl.t; max_known : unit -> int }

  let create ?(max_known = fun () -> 100_000) () =
    { known = Hashtbl.create 4096; max_known }

  let remember t key =
    if Hashtbl.length t.known >= t.max_known () then Hashtbl.reset t.known;
    Hashtbl.replace t.known key ()

  let count t = Hashtbl.length t.known
end

module Over (Io : Io.S) (Pools : Bounded.S with type 'a io := 'a Io.t) = struct
  open Io_syntax.Make (Io)

  (* The memo, then the marker, then the store: a chunk this session placed
     whose marker says it is not what landed must not read as stored, or the
     bad bytes reach every later file containing it. *)
  let known t ~corrupt ~present key =
    let* marked = corrupt key in
    if marked then Io.return false
    else if Hashtbl.mem t.Dedup.known key then Io.return true
    else present key

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
    val ranges : Pools.t
    val max_known : unit -> int
  end

  module Make (D : DEPS) = struct
    open Io_syntax.Make (Io)

    (* Not pre-populated by listing the chunk prefix: that cost scales with the
       whole historical archive rather than the upload at hand. *)
    let dedup = Dedup.create ~max_known:D.max_known ()
    let known_count () = Dedup.count dedup

    (* [data] must own its bytes: a store is free to keep sending after this
       returns, and the key is the hash of what was passed, not of what lands. *)
    let put data =
      let key = Chunks.key_of_body data in
      Metrics.add_hashed 1;
      let* known = known dedup ~corrupt:D.corrupt ~present:D.present key in
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

    (* Its own budget, not [downloads]: every caller of this is a reader waiting
       on bytes, and a whole-chunk fetch is mostly the prefetch running ahead of
       one. Sharing the budget put the reader in a queue the prefetch refills as
       fast as it drains -- a 128 KiB ask waiting behind eight 1 MiB transfers,
       which on a phone is six seconds a read. *)
    let fetch_range key ~offset ~length =
      Pools.use D.ranges (fun () -> D.fetch_body_range key ~offset ~length)
  end
end
