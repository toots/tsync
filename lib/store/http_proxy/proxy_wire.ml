open Tsync_core
open Tsync_store

let max_clock_skew = 300.
let bulk_keys_max = 1024
let bulk_folders_max = 64
let bulk_answer_budget = 8 * 1024 * 1024
let watch_max = 30.

let unreserved = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '-' | '.' | '_' | '~' | '!' | '$' | '\'' | '(' | ')' | '*' | ':' | '@' | '/'
  | '?' ->
      true
  | _ -> false

let allowed_in_key c = unreserved c || c = ','
let allowed_in_value c = unreserved c || c = '='

let escape allowed s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if allowed c then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let canonical_query params =
  String.concat "&"
    (List.map
       (fun (k, v) -> escape allowed_in_key k ^ "=" ^ escape allowed_in_value v)
       params)

let unescape s =
  let b = Buffer.create (String.length s) in
  let hex c =
    match c with
      | '0' .. '9' -> Some (Char.code c - 48)
      | 'a' .. 'f' -> Some (Char.code c - 87)
      | 'A' .. 'F' -> Some (Char.code c - 55)
      | _ -> None
  in
  let n = String.length s in
  let rec go i =
    if i >= n then Some (Buffer.contents b)
    else if s.[i] = '%' then
      if i + 2 >= n then None
      else (
        match (hex s.[i + 1], hex s.[i + 2]) with
          | Some a, Some c ->
              Buffer.add_char b (Char.chr ((a * 16) + c));
              go (i + 3)
          | _ -> None)
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0

let parse_query raw =
  if raw = "" then Some []
  else (
    let rec go seen acc = function
      | [] -> Some (List.rev acc)
      | part :: rest -> (
          match String.index_opt part '=' with
            | None -> None
            | Some i -> (
                match
                  ( unescape (String.sub part 0 i),
                    unescape
                      (String.sub part (i + 1) (String.length part - i - 1)) )
                with
                  | Some k, Some v when not (List.mem k seen) ->
                      go (k :: seen) ((k, v) :: acc) rest
                  | _ -> None))
    in
    go [] [] (String.split_on_char '&' raw))

let signature ~secret ~meth ~target ~timestamp body =
  let body_hash = Digestif.SHA256.(to_hex (digest_bigstring body)) in
  Digestif.SHA256.(
    to_hex
      (hmac_string ~key:secret
         (String.concat "\n" [meth; target; timestamp; body_hash])))

let sign ~secret ~meth ~target body =
  let timestamp = string_of_int (int_of_float (Unix.gettimeofday ())) in
  [
    ("x-tsync-timestamp", timestamp);
    ("x-tsync-signature", signature ~secret ~meth ~target ~timestamp body);
  ]

let fresh ~now timestamp =
  let n = String.length timestamp in
  n >= 1 && n <= 15
  && String.for_all (fun c -> c >= '0' && c <= '9') timestamp
  && Float.abs (now -. float_of_string timestamp) <= max_clock_skew

let verify ~secret ~meth ~target ~timestamp ~signature:given body =
  Eqaf.equal given (signature ~secret ~meth ~target ~timestamp body)

let encode_key k =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    (Key.to_string k)

let decode_key s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok k -> Key.of_string k
    | Error _ -> None

let listing_to_json entries =
  Yojson.Safe.to_string
    (`List
       (List.map
          (fun (e : Store.entry) ->
            `Assoc
              ([
                 ("key", `String (Key.to_string e.key));
                 ("size", `Int e.size);
                 ("lastModified", `Float e.last_modified);
               ]
              @ Option.fold ~none:[]
                  ~some:(fun t -> [("etag", `String t)])
                  e.etag))
          entries))

let corrupt fmt = Fail.corrupt fmt

let listing_of_json s =
  match Yojson.Safe.from_string s with
    | `List l ->
        List.filter_map
          (function
            | `Assoc f -> (
                let key =
                  match List.assoc_opt "key" f with
                    | Some (`String k) -> k
                    | _ -> corrupt "a listing entry without a key"
                in
                let size =
                  match List.assoc_opt "size" f with
                    | Some (`Int n) when n >= 0 -> n
                    | _ -> corrupt "a listing entry without a size"
                in
                let last_modified =
                  match List.assoc_opt "lastModified" f with
                    | Some (`Int n) -> float_of_int n
                    | Some (`Float x) -> x
                    | _ -> corrupt "a listing entry without a time"
                in
                let etag =
                  match List.assoc_opt "etag" f with
                    | Some (`String t) -> Some t
                    | _ -> None
                in
                match Store.listed "http-proxy" key with
                  | Some key -> Some { Store.key; size; last_modified; etag }
                  | None -> None)
            | _ -> corrupt "a listing entry that is not an object")
          l
    | _ -> corrupt "a listing that is not an array"
    | exception Yojson.Json_error _ -> corrupt "a listing that is not JSON"

let absent = 0xFFFFFFFF

let set_u32 b off n =
  Bigarray.Array1.unsafe_set b off (Char.chr ((n lsr 24) land 0xff));
  Bigarray.Array1.unsafe_set b (off + 1) (Char.chr ((n lsr 16) land 0xff));
  Bigarray.Array1.unsafe_set b (off + 2) (Char.chr ((n lsr 8) land 0xff));
  Bigarray.Array1.unsafe_set b (off + 3) (Char.chr (n land 0xff))

let get_u32 b off =
  (Char.code (Bigarray.Array1.get b off) lsl 24)
  lor (Char.code (Bigarray.Array1.get b (off + 1)) lsl 16)
  lor (Char.code (Bigarray.Array1.get b (off + 2)) lsl 8)
  lor Char.code (Bigarray.Array1.get b (off + 3))

(* A frame writer over pieces: sizes are summed first, so the answer is one
   allocation. *)
type piece = U32 of int | Bytes of Bigstring.t

let assemble pieces =
  let size =
    List.fold_left
      (fun n -> function U32 _ -> n + 4 | Bytes b -> n + Bigstring.length b)
      0 pieces
  in
  let out = Bigstring.create size in
  ignore
    (List.fold_left
       (fun off -> function
         | U32 n ->
             set_u32 out off n;
             off + 4
         | Bytes b ->
             Bigstring.blit ~src:b ~src_off:0 ~dst:out ~dst_off:off
               ~len:(Bigstring.length b);
             off + Bigstring.length b)
       0 pieces);
  out

let field b = [U32 (Bigstring.length b); Bytes b]
let text s = field (Bigstring.of_string s)
let body = function Some b -> field b | None -> [U32 absent]
let encode_bodies bodies = assemble (List.concat_map body bodies)

let encode_folders folders =
  assemble
    (List.concat_map
       (fun (f : Store.folder) ->
         text (Key.prefix_to_string f.prefix)
         @ text (listing_to_json f.listing)
         @ U32 (List.length f.bodies)
           :: List.concat_map
                (fun (k, b) -> text (Key.to_string k) @ body b)
                f.bodies)
       folders)

(* Every length is bounded by the bytes remaining, never by [pos + n]. *)
type cursor = { buf : Bigstring.t; mutable pos : int }

let remaining c = Bigstring.length c.buf - c.pos

let u32 c =
  if remaining c < 4 then corrupt "a frame cut inside a length";
  let n = get_u32 c.buf c.pos in
  c.pos <- c.pos + 4;
  n

let bytes c n =
  if n > remaining c then corrupt "a frame whose length runs past the end";
  let b = Bigstring.sub c.buf ~off:c.pos ~len:n in
  c.pos <- c.pos + n;
  b

let read_body c =
  match u32 c with n when n = absent -> None | n -> Some (bytes c n)

let read_text c = Bigstring.to_string (bytes c (u32 c))

let decode_bodies ~count buf =
  let c = { buf; pos = 0 } in
  let bodies = List.init count (fun _ -> read_body c) in
  if remaining c <> 0 then corrupt "a get-multi answer with bytes left over";
  bodies

let decode_folders ~asked buf =
  let c = { buf; pos = 0 } in
  let rec folders acc =
    if remaining c = 0 then List.rev acc
    else (
      let prefix =
        match Key.prefix_of_string (read_text c) with
          | Some p
            when List.exists
                   (fun a -> Key.prefix_to_string a = Key.prefix_to_string p)
                   asked ->
              p
          | _ -> corrupt "a children-multi folder that was not asked for"
      in
      let listing = listing_of_json (read_text c) in
      let count = u32 c in
      let bodies =
        List.init count (fun _ ->
            let k =
              match Key.of_string (read_text c) with
                | Some k when Key.under prefix k -> k
                | _ -> corrupt "a children-multi child outside its folder"
            in
            (k, read_body c))
      in
      folders ({ Store.prefix; listing; bodies } :: acc))
  in
  folders []
