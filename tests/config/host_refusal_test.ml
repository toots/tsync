open Tsync_config

let proxy =
  {|{"type":"http-proxy","name":"nas","role":"main","url":"https://nas.example:8443","secret":"0123456789abcdef0123456789abcdef"}|}

let config ~backend ~frontend =
  Printf.sprintf
    {|{"domains":[{"name":"F","versioning":true,"extensions":[],"backends":[%s],"frontends":["%s"]}]}|}
    backend frontend

(* Printed the same everywhere: [ok] when refused exactly where the host is
   Windows (cloud-files §2), and a config built in code is never refused. *)
let check name text ~refused_on_windows =
  let refused =
    match Config.of_user_string text with
      | _ -> false
      | exception Config.Invalid _ -> true
  in
  let expected = refused_on_windows && Sys.win32 in
  let in_code =
    match Config.of_string text with _ -> true | exception _ -> false
  in
  Printf.printf "%s %s\n"
    (if refused = expected && in_code then "ok  " else "FAIL")
    name

let () =
  check "a local store"
    (config
       ~backend:
         {|{"type":"local","name":"main","role":"main","path":"/srv/tsync"}|}
       ~frontend:"android")
    ~refused_on_windows:true;
  check "the http-proxy frontend"
    (config ~backend:proxy ~frontend:"http-proxy")
    ~refused_on_windows:true;
  check "an http-proxy backend"
    (config ~backend:proxy ~frontend:"android")
    ~refused_on_windows:false
