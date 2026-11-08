open Tsync_config

let proxy ~name ~role url =
  Printf.sprintf
    {|{"type":"http-proxy","name":"%s","role":"%s","url":"%s","secret":"0123456789abcdef0123456789abcdef"}|}
    name role url

let config domains =
  Printf.sprintf {|{"name":"laptop","domains":[%s]}|}
    (String.concat "," domains)

let () =
  print_endline
    (Config_summary.render
       (Config.of_string
          (config
             [
               Printf.sprintf
                 {|{"name":"Laura + Romain","versioning":true,"extensions":["passwords","totp"],"backends":[%s,%s],"frontends":["android"]}|}
                 (proxy ~name:"server" ~role:"main" "https://tsync.example.org")
                 (proxy ~name:"nas" ~role:"replica" "https://nas.example");
               Printf.sprintf
                 {|{"name":"archive","versioning":true,"backends":[%s],"frontends":["android"]}|}
                 (proxy ~name:"server" ~role:"readOnly"
                    "https://tsync.example.org");
             ])));
  print_endline "--";
  print_endline (Config_summary.render (Config.of_string (config [])))
