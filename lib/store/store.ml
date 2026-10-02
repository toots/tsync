open Tsync_core

type entry = {
  key : Key.t;
  size : int;
  last_modified : float;
  etag : string option;
  checksum : Checksum.t option;
}

type caps = {
  share_url : string option;
  chunk_size : int option;
  max_concurrency : int option;
  verified : bool;
}

type claim = Won | Held of Bigstring.t
type mode = Wait | Best_effort
type replaced = Written | Changed
type locality = Local | Proxy | Remote

type folder = {
  prefix : Key.prefix;
  listing : entry list;
  bodies : (Key.t * Bigstring.t option) list;
}

type traffic = { uploaded : int Atomic.t; downloaded : int Atomic.t }

type t = {
  name : string;
  put : ?mode:mode -> Key.t -> Bigstring.t -> unit;
  put_if_absent : Key.t -> Bigstring.t -> claim;
  put_if_unchanged : Key.t -> Bigstring.t -> entry option -> replaced;
  get_opt : Key.t -> Bigstring.t option;
  get_range : Key.t -> int -> int -> Bigstring.t option;
  head_opt : Key.t -> entry option;
  compute_checksum : Key.t -> string -> Checksum.t option;
  delete : Key.t -> bool;
  delete_multi : Key.t list -> unit;
  copy : Key.t -> Key.t -> unit;
  list_prefix : ?max_keys:int -> Key.prefix -> entry list;
  watch : Key.t -> string option -> unit;
  get_many : (Key.t list -> Bigstring.t option list) option;
  list_many : (Key.prefix list -> folder list) option;
  bucket_functions : bool;
  capabilities : Key.prefix -> caps;
  fast_read : bool;
  locality : locality;
  local_path : string option;
  health : Health.t;
  traffic : traffic option;
}

let no_caps =
  {
    share_url = None;
    chunk_size = None;
    max_concurrency = None;
    verified = false;
  }

let new_traffic () = { uploaded = Atomic.make 0; downloaded = Atomic.make 0 }

let get s k =
  match s.get_opt k with
    | Some b -> b
    | None ->
        Fail.absent
          ~op:("get " ^ Key.to_string k)
          "%s: no such object on %s" (Key.to_string k) s.name

let watch_interval = 2.

(* 06 §2.4: the watched value is the body with surrounding whitespace removed. *)
let token body = Option.map (fun b -> String.trim (Bigstring.to_string b)) body

(* Keys are valid by construction; what is left to refuse before any request
   is a malformed range, and empty bulk lists issue no request. *)
let checked s =
  {
    s with
    get_range =
      (fun key off len ->
        if len <= 0 || off < 0 then
          Fail.invalid ~op:"get_range" "bad range %d+%d" off len;
        s.get_range key off len);
    delete_multi = (fun keys -> if keys <> [] then s.delete_multi keys);
    put_if_unchanged =
      (fun key body expected ->
        match expected with
          | Some { etag = None; _ } ->
              Fail.raise_ Fail.Refused
                "%s: %s was read without a version, so it cannot be \
                 replaced                  conditionally"
                s.name (Key.to_string key)
          | _ -> s.put_if_unchanged key body expected);
    compute_checksum =
      (fun key algo ->
        if not (Checksum.known algo) then
          Fail.invalid ~op:"compute_checksum" "unknown checksum algorithm %S"
            algo;
        s.compute_checksum key algo);
    get_many =
      Option.map (fun f keys -> if keys = [] then [] else f keys) s.get_many;
    list_many =
      Option.map (fun f ps -> if ps = [] then [] else f ps) s.list_many;
  }

(* A listed name that is not a valid key is skipped with a warning, never
   mapped to anything. *)
let listed store_name name =
  match Key.of_string name with
    | Some k -> Some k
    | None ->
        Log.once ("invalid-listed:" ^ name) Warn
          "%s: skipping listed name %S, not a valid key" store_name name;
        None

let max_batch_keys = 256
let max_batch_bytes = 8 * 1024 * 1024
let max_batch_folders = 64

(* 06 §5: the one way to read many keys. A batch that fails permanently is
   answered key by key; a transient failure is raised. *)
let read_many s (entries : entry list) =
  match s.get_many with
    | None -> List.map (fun e -> (e.key, s.get_opt e.key)) entries
    | Some f ->
        let rec batches acc cur n bytes = function
          | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
          | e :: rest ->
              if
                cur <> []
                && (n >= max_batch_keys || bytes + e.size > max_batch_bytes)
              then batches (List.rev cur :: acc) [e] 1 e.size rest
              else batches acc (e :: cur) (n + 1) (bytes + e.size) rest
        in
        List.concat_map
          (fun batch ->
            let keys = List.map (fun e -> e.key) batch in
            match f keys with
              | bodies -> List.combine keys bodies
              | exception (Fail.E fl as ex) when not (Fail.retryable fl.kind) ->
                  ignore ex;
                  List.map (fun k -> (k, s.get_opt k)) keys)
          (batches [] [] 0 0 entries)

let count_up s n =
  Option.iter (fun t -> ignore (Atomic.fetch_and_add t.uploaded n)) s.traffic

let count_down s n =
  Option.iter (fun t -> ignore (Atomic.fetch_and_add t.downloaded n)) s.traffic
