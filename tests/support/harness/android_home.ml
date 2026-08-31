(* Pointing a tsync at a scratch home, and asking it what that means. *)

type paths = { config : string; cache : string }

let vars = ["XDG_CONFIG_HOME"; "XDG_CACHE_HOME"; "XDG_DATA_HOME"]

let env ~home =
  Printf.sprintf "env %s HOME=%s"
    (String.concat " " (List.map (fun v -> "-u " ^ v) vars))
    (Filename.quote home)

(* Pointed at [home] rather than removed: there is no portable way to unset a
   variable from OCaml, and a Linux lookup lands in the same place either
   way. *)
let adopt ~home =
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_CONFIG_HOME" (Filename.concat home ".config");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat home ".cache");
  Unix.putenv "XDG_DATA_HOME" (Filename.concat home ".local/share")

let read_file path =
  match open_in_bin path with
    | ic ->
        let s = really_input_string ic (in_channel_length ic) in
        close_in ic;
        s
    | exception _ -> ""

let field name text =
  let tag = name ^ ":" in
  let n = String.length tag in
  let of_line l =
    if String.length l > n && String.sub l 0 n = tag then
      Some (String.trim (String.sub l n (String.length l - n)))
    else None
  in
  List.filter_map of_line (String.split_on_char '\n' text)

let paths ~tsync ~home ~scratch =
  let out = Filename.concat scratch "build-info.txt" in
  ignore
    (Sys.command
       (Printf.sprintf "%s %s build-info > %s 2>/dev/null" (env ~home)
          (Filename.quote tsync) (Filename.quote out)));
  let text = read_file out in
  let one name fallback =
    match field name text with path :: _ -> path | [] -> fallback home
  in
  {
    config =
      one "config" (fun h -> Filename.concat h ".config/tsync/config.json");
    cache = one "cache" (fun h -> Filename.concat h ".cache/tsync");
  }
