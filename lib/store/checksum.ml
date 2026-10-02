open Tsync_core

type t = { algo : string; value : string }

let md5 = "md5"
let known algo = algo = md5
let comparable a b = a.algo = b.algo
let to_string c = c.algo ^ ":" ^ c.value

let is_hex s =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let md5_of_hex s =
  let s = String.lowercase_ascii s in
  if String.length s = 32 && is_hex s then Some { algo = md5; value = s }
  else None

let md5_of_base64 s =
  match Base64.decode s with
    | Ok raw when String.length raw = 16 ->
        Some
          {
            algo = md5;
            value =
              String.concat ""
                (List.map
                   (fun c -> Printf.sprintf "%02x" (Char.code c))
                   (List.of_seq (String.to_seq raw)));
          }
    | _ -> None

let of_string s =
  match String.index_opt s ':' with
    | Some i when String.sub s 0 i = md5 ->
        let value = String.sub s (i + 1) (String.length s - i - 1) in
        if String.length value = 32 && is_hex value then
          Some { algo = md5; value }
        else None
    | _ -> None

let check algo =
  if not (known algo) then Fail.invalid "unknown checksum algorithm %S" algo

let of_body algo body =
  check algo;
  { algo; value = Digestif.MD5.(to_hex (digest_bigstring body)) }
