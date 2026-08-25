open Lwt.Syntax

module type DEPS = sig
  val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit Lwt.t
  val backend_key : string -> Stored_key.t
  val present : string -> bool Lwt.t
  val fetch_body : string -> Bigstring.t Lwt.t
  val corrupt : string -> bool Lwt.t
  val cleared : string -> unit
  val slots : Io_lwt.Bounded.t
  val downloads : Io_lwt.Bounded.t
  val max_known : unit -> int
end

module Make (D : DEPS) = struct
  (* Not pre-populated by listing the chunk prefix: that cost scales with the
     whole historical archive rather than the upload at hand. *)
  let dedup = Dedup.create ~max_known:D.max_known ()
  let known_count () = Dedup.count dedup

  (* [data] must own its bytes: a store is free to keep sending after this
     returns, and the key is the hash of what was passed, not of what lands. *)
  let put data =
    let key = Chunks.key_of_body data in
    Metrics.add_hashed 1;
    let* known = Dedup.known dedup ~corrupt:D.corrupt ~present:D.present key in
    let+ () =
      if known then (
        Dedup.remember dedup key;
        Lwt.return_unit)
      else
        let+ () = D.put ~key:(D.backend_key key) ~data () in
        D.cleared key;
        Dedup.remember dedup key
    in
    (key, not known)

  let store = function
    | Chunk_source.Stored key -> Lwt.return (key, false)
    | Mapped bytes -> Io_lwt.Bounded.use D.slots (fun () -> put (bytes ()))
    | Filled { len; fill } ->
        Io_lwt.Bounded.use D.slots (fun () ->
            let buf = Bigstring.create len in
            let* () = fill buf in
            put buf)

  let fetch key = Io_lwt.Bounded.use D.downloads (fun () -> D.fetch_body key)
end
