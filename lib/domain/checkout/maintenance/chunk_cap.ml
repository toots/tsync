(** Holding the local chunk store under [max_cache].

    Every chunk here is re-fetchable, so this needs no residency, open counts or
    dirty checks: it drops the coldest bodies until the store is under its cap,
    and a read that misses fetches again.

    The store counts itself as it writes ({!Chunk_cache} keeps the count on the
    write path, where the bytes are known). What lives here is the policy over
    that count -- when it is trustworthy, when the store is over, and what goes
    first. *)

open Sweep

module type FILES = sig
  type 'a io

  val unlink_quiet : string -> unit io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
end

(** The store, for what only it can answer: what it holds, and what it counts
    itself as holding. Already built for the domain — the cache is made with a
    backend to fetch through, so this takes the instance rather than making one.
*)
module type STORE = sig
  type 'a io

  val root : unit -> string

  (** (path, bytes, mtime) per chunk body. *)
  val entries : unit -> (string * int * float) list io

  val held : unit -> Chunk_cache.held
  val dropped : int -> unit

  (** Drop the partial-body record beside [body], if there is one. *)
  val drop_record : body:string -> unit io
end

module Make
    (Io : Io.S)
    (Files : FILES with type 'a io := 'a Io.t)
    (Retry : SYSCALLS with type 'a io := 'a Io.t)
    (S : STORE with type 'a io := 'a Io.t)
    (C : Conf.S with type 'a io = 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()

  (* Exact, so the count is set from it wherever it runs. *)
  let recount items =
    let h = S.held () in
    h.Chunk_cache.anchored <- true;
    h.Chunk_cache.files <- List.length items;
    h.Chunk_cache.bytes <-
      List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items

  (* The one walk left, and it is once per store per process rather than once
     per upload and once per status request, which is what it used to be.

     The existence check is not the walk: a resync drops the whole tree
     ({!Cache_layout.clear}), which no delta reaches, so a count that outlived
     its store is thrown away rather than trusted. One stat, against a walk of
     every shard. *)
  let anchor () =
    let h = S.held () in
    let* here = Retry.file_exists (S.root ()) in
    if not here then (
      h.Chunk_cache.anchored <- true;
      h.Chunk_cache.files <- 0;
      h.Chunk_cache.bytes <- 0;
      return_unit)
    else if h.Chunk_cache.anchored then return_unit
    else
      let+ items = Io.catch S.entries (fun _ -> Io.return []) in
      recount items

  let stats () =
    let+ () = anchor () in
    let h = S.held () in
    (h.Chunk_cache.files, h.Chunk_cache.bytes)

  (* Coldest first. Best-effort: a chunk deleted under an in-flight read is
     fetched again.

     The count says whether there is anything to do; the walk happens only
     when there is, because choosing what to drop needs an mtime per body and
     nothing short of reading them has one. *)
  let run () =
    match C.max_cache with
      | None -> Io.return nothing
      | Some cap ->
          let* () = anchor () in
          if (S.held ()).Chunk_cache.bytes <= cap then Io.return nothing
          else
            let* items = Io.catch S.entries (fun _ -> Io.return []) in
            recount items;
            if (S.held ()).Chunk_cache.bytes <= cap then Io.return nothing
            else (
              let coldest =
                List.sort (fun (_, _, a) (_, _, b) -> compare a b) items
              in
              let rec go acc = function
                | [] -> Io.return acc
                | _ when (S.held ()).Chunk_cache.bytes <= cap -> Io.return acc
                | (path, bytes, _) :: rest ->
                    Log.debug "chunk cache: dropping %s (%d bytes)"
                      (Filename.basename path) bytes;
                    let* () = Files.unlink_quiet path in
                    S.dropped bytes;
                    (* After the body, so a crash leaves a record about a body
                       that is gone -- read as an empty group -- rather than a
                       partial body read as a whole one. *)
                    let* () = S.drop_record ~body:path in
                    go { files = acc.files + 1; bytes = acc.bytes + bytes } rest
              in
              go nothing coldest)
end
