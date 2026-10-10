let max_bytes = 300 * 1024
let size = 800
let min_side = 300
let timeout = 20.

(* http-proxy §A9.8: the frame header of tsync's own encoder output, nothing
   more. *)
let dimensions s =
  let n = String.length s in
  let byte i = Char.code s.[i] in
  let u16 i = (byte i lsl 8) lor byte (i + 1) in
  let rec past_fill j =
    if j >= n then None else if byte j = 0xFF then past_fill (j + 1) else Some j
  in
  let rec segment i =
    if i >= n || byte i <> 0xFF then None
    else (
      match past_fill (i + 1) with
        | None -> None
        | Some j ->
            let m = byte j in
            if (m >= 0xD0 && m <= 0xD7) || m = 0x01 then segment (j + 1)
            else if m = 0x00 || m = 0xDA || m = 0xD9 || j + 2 >= n then None
            else (
              let len = u16 (j + 1) in
              if len < 2 || j + 1 + len > n then None
              else if m = 0xC0 || m = 0xC2 then
                if len < 8 then None
                else (
                  let precision = byte (j + 3)
                  and height = u16 (j + 4)
                  and width = u16 (j + 6)
                  and components = byte (j + 8) in
                  if
                    precision = 8 && height > 0 && width > 0
                    && (components = 1 || components = 3)
                  then Some (width, height)
                  else None)
              else if
                m >= 0xC1 && m <= 0xCF && m <> 0xC4 && m <> 0xC8 && m <> 0xCC
              then None
              else segment (j + 1 + len)))
  in
  if
    n >= 4
    && byte 0 = 0xFF
    && byte 1 = 0xD8
    && byte (n - 2) = 0xFF
    && byte (n - 1) = 0xD9
  then segment 2
  else None

let valid b =
  Bigstring.length b <= max_bytes
  &&
    match dimensions (Bigstring.to_string b) with
    | Some (w, h) -> max w h = size && min w h >= min_side
    | None -> false

type kind = [ `Image | `Video | `Audio ]

let kind_of_name name =
  match Mime.of_name name with
    | Some m when String.starts_with ~prefix:"image/" m -> Some `Image
    | Some m when String.starts_with ~prefix:"video/" m -> Some `Video
    | Some m when String.starts_with ~prefix:"audio/" m -> Some `Audio
    | _ -> None

let thumbnailer :
    (kind:kind -> deadline:float -> string -> Bigstring.t option) option
    Atomic.t =
  Atomic.make None

let available () = Option.is_some (Atomic.get thumbnailer)

let make ~kind url =
  match Atomic.get thumbnailer with
    | None -> None
    | Some make -> (
        match make ~kind ~deadline:(Rt.now () +. timeout) url with
          | Some b when valid b -> Some b
          | Some _ ->
              Log.debug "share preview: the image made is not valid";
              None
          | None -> None
          | exception e when not (Rt.is_cancelled e) ->
              Log.debug "share preview: %s" (Printexc.to_string e);
              None)
