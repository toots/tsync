(* The media helper (Tsync_core.Media_helper): one request on standard input,
   its image on standard output. *)

open Tsync_core
module Share_preview_av = Tsync_preview_av.Share_preview_av

let fail fmt =
  Printf.ksprintf
    (fun message ->
      prerr_endline ("tsync-media: " ^ message);
      exit 1)
    fmt

let int_arg name text =
  match int_of_string_opt text with
    | Some n when n > 0 -> n
    | _ -> fail "%s is not a positive count: %S" name text

let answer ~deadline = function
  | ["thumbnail"; kind; url] -> (
      match Share_preview.kind_of_string kind with
        | Some kind ->
            Bigstring.to_string (Share_preview_av.thumbnail ~kind ~deadline url)
        | None -> fail "unknown kind %S" kind)
  | ["icon"; max_side; max_bytes; source] ->
      Share_preview_av.icon
        ~max_side:(int_arg "the side" max_side)
        ~max_bytes:(int_arg "the size" max_bytes)
        ~deadline source
  | command :: _ -> fail "unknown request %S" command
  | [] -> fail "empty request"

let () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  match Media_helper.read_request (In_channel.input_all stdin) with
    | None -> fail "no request on standard input"
    | Some (deadline, request) -> (
        match answer ~deadline request with
          | image ->
              print_string image;
              exit 0
          | exception e -> fail "%s" (Printexc.to_string e))
