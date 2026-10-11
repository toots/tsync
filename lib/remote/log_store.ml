open Tsync_core
open Tsync_store

let cursor_interval = 2.

type t = {
  domain : Domain_name.t;
  store : Store.t;
  m : Mutex.t;
  mutable pending : int option;
  mutable last_publish : float;
  mutable armed : bool;
}

let create domain store =
  {
    domain;
    store;
    m = Mutex.create ();
    pending = None;
    last_publish = neg_infinity;
    armed = false;
  }

type read =
  | Entry of Log_entry.t
  | Void
  | Later_version of int
  | Undecodable of string

type entry = { n : int; bytes : string; read : read }

let commands e =
  match e.read with
    | Entry { commands; _ } -> Some commands
    | Void -> Some []
    | Later_version _ | Undecodable _ -> None

let claim_holder : Store.claim -> [ `Won | `Held of string ] = function
  | Won -> `Won
  | Held b -> `Held (String.trim (Bigstring.to_string b))

let void_exists t n = t.store.head_opt (Key.void t.domain n) <> None

let void_create t n ~client =
  claim_holder
    (t.store.put_if_absent (Key.void t.domain n) (Bigstring.of_string client))

let entry_of t n body =
  let bytes = Bigstring.to_string body in
  let read =
    match Log_entry.decode bytes with
      | `Entry e -> Entry e
      | `Later_version v -> Later_version v
      | `Corrupt what ->
          if void_exists t n then Void else Undecodable ("expected " ^ what)
  in
  { n; bytes; read }

let read_entry t n =
  Option.map (entry_of t n) (t.store.get_opt (Key.log_entry t.domain n))

let batch = 32

let read_entries t from =
  let rec sequential = function
    | [] -> []
    | key :: rest -> (
        match t.store.get_opt key with
          | None -> [None]
          | found -> found :: sequential rest)
  in
  let rec take acc numbers bodies =
    match (numbers, bodies) with
      | n :: numbers, Some body :: bodies ->
          take (entry_of t n body :: acc) numbers bodies
      | _, None :: _ -> `Done acc
      | _ -> `More acc
  in
  let rec go from acc =
    let numbers = List.init batch (fun i -> from + i) in
    let keys = List.map (Key.log_entry t.domain) numbers in
    let bodies =
      match t.store.get_many with
        | Some get_many -> get_many keys
        | None -> sequential keys
    in
    match take acc numbers bodies with
      | `Done acc -> List.rev acc
      | `More acc -> go (from + batch) acc
  in
  go from []

let create_entry t n body =
  match
    t.store.put_if_absent (Key.log_entry t.domain n) (Bigstring.of_string body)
  with
    | Won -> `Won
    | Held _ -> `Held

let tree_head t =
  match t.store.get_opt (Key.tree_head t.domain) with
    | None -> 0
    | Some body -> (
        match Yojson.Safe.from_string (Bigstring.to_string body) with
          | `Assoc l -> (
              match List.assoc_opt "n" l with
                | Some (`Int n) when n >= 0 -> n
                | _ -> Fail.corrupt "tree head: expected a number")
          | _ | (exception Yojson.Json_error _) ->
              Fail.corrupt "tree head: expected a JSON object")

let raise_tree_head t n =
  if tree_head t < n then
    t.store.put (Key.tree_head t.domain)
      (Bigstring.of_string (Printf.sprintf "{\"n\":%d}" n))

let takeover t n =
  let rec up g holder =
    match t.store.get_opt (Key.takeover t.domain n ~generation:(g + 1)) with
      | Some b -> up (g + 1) (Some (String.trim (Bigstring.to_string b)))
      | None -> (g, holder)
  in
  up 0 None

let takeover_create t n ~generation ~client =
  claim_holder
    (t.store.put_if_absent
       (Key.takeover t.domain n ~generation)
       (Bigstring.of_string client))

let cursor_read t =
  match t.store.get_opt (Key.cursor t.domain) with
    | None -> `None
    | Some b -> (
        match int_of_string_opt (String.trim (Bigstring.to_string b)) with
          | Some n when n >= 0 -> `At n
          | _ -> `Moved)

let cursor_token t = Store.token (t.store.get_opt (Key.cursor t.domain))
let cursor_wait t token = t.store.watch (Key.cursor t.domain) token

let cursor_flush t =
  let pending =
    Mutex.protect t.m (fun () ->
        let p = t.pending in
        t.pending <- None;
        p)
  in
  match pending with
    | None -> ()
    | Some n -> (
        try
          t.store.put (Key.cursor t.domain)
            (Bigstring.of_string (Key.entry_number n));
          Mutex.protect t.m (fun () -> t.last_publish <- Rt.now ())
        with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e ->
              Log.warn "cursor note of %d dropped: %s" n (Printexc.to_string e))

let cursor_note t n =
  let arm =
    Mutex.protect t.m (fun () ->
        t.pending <- Some (max n (Option.value ~default:0 t.pending));
        if t.armed then None
        else (
          t.armed <- true;
          Some (max 0. (cursor_interval -. (Rt.now () -. t.last_publish)))))
  in
  Option.iter
    (fun delay ->
      Rt.spawn ~name:"cursor" (fun () ->
          (* A stop leaves it armed: the pending number is the drain's to flush. *)
          Stop.sleep delay;
          Mutex.protect t.m (fun () -> t.armed <- false);
          cursor_flush t))
    arm
