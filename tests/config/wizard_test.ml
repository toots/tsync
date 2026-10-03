(* The config wizard (spec 07 §5.9) answered from a script: each prompt and
   its answer printed, then the JSON it would write. *)

open Tsync_config

let p fmt = Printf.printf fmt

(* Answers by a substring of the prompt's label, in order; any other prompt
   gets a blank answer, which keeps or defaults. *)
let scripted rules =
  let rules = List.map (fun (k, answers) -> (k, ref answers)) rules in
  let asked = ref 0 in
  {
    Config_wizard.ask =
      (fun pr ->
        incr asked;
        if !asked > 200 then failwith "the script ran out";
        let contains s sub =
          let n = String.length sub in
          let rec go i =
            i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
          in
          go 0
        in
        let answer =
          match
            List.find_opt (fun (k, q) -> contains pr.label k && !q <> []) rules
          with
            | Some (_, q) ->
                let a = List.hd !q in
                q := List.tl !q;
                a
            | None -> ""
        in
        let host = Config.hostname () in
        p "? %s%s -> %s\n" pr.label
          (match pr.default with
            | Some d when d = host -> " [<host>]"
            | Some d -> " [" ^ d ^ "]"
            | None -> "")
          (if pr.secret && answer <> "" then "(secret)" else answer);
        answer);
    say = (fun s -> p "  %s\n" s);
  }

let finish label j =
  match j with
    | None -> p "%s: quit\n" label
    | Some j -> (
        match Config_wizard.prepare j with
          | Ok j ->
              p "%s: would write\n%s\n" label (Yojson.Safe.pretty_to_string j)
          | Error e -> p "%s: refused: %s\n" label e)

let () =
  p "== a new config\n";
  finish "new"
    (Config_wizard.edit
       (scripted
          [
            ("client name", ["laptop"]);
            ("domain name", ["docs"]);
            ("backends:", ["a"; "d"]);
            ("type (", ["local"]);
            ("backend name", ["main"]);
            ("Store root", ["/srv/docs"]);
            ("frontends:", ["a"; "d"]);
            ("frontend (", ["http-proxy"]);
            ("Port", ["5446"]);
            ("Shared secret", [String.make 32 'a']);
            ("[w]rite", ["w"]);
          ])
       None);
  p
    "\n\
     == an existing config: what is not asked is kept, an unused link dropped\n";
  let existing =
    Yojson.Safe.from_string
      {|{"name":"box","links":{"wan":{"maxRate":1000,"minRate":200},"gone":{"maxRate":5}},
        "domains":[{"name":"docs","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
          "backends":[{"type":"local","name":"main","role":"main","path":"/srv/docs"},
                      {"type":"http-proxy","name":"far","role":"replica","link":"wan",
                       "url":"https://far.example:5446","secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}]}|}
  in
  finish "edit"
    (Config_wizard.edit
       (scripted
          [
            ("[w]rite", ["e 1"; "w"]);
            ("cache limit", ["2 GiB"]);
            ("backends:", ["a"; "d"]);
            ("type (", ["local"]);
            ("backend name", ["copy"]);
            ("role", [""]);
            ("Store root", ["/srv/copy"]);
            ("frontends:", ["d"]);
          ])
       (Some existing));
  p "\n== invalid answers are asked again\n";
  finish "invalid"
    (Config_wizard.edit
       (scripted
          [
            ("[w]rite", ["e 1"; "w"]);
            ("symlinks", ["sometimes"; "skip"]);
            ("cache limit", ["lots"]);
            ("backends:", ["d"]);
            ("frontends:", ["d"]);
          ])
       (Some existing));
  p "\n== quit\n";
  finish "quit"
    (Config_wizard.edit (scripted [("[w]rite", ["q"])]) (Some existing));
  p "\n== not an object\n";
  match Config_wizard.edit (scripted []) (Some (`List [])) with
    | _ -> p "accepted\n"
    | exception Tsync_core.Fail.E f -> p "refused: %s\n" f.reason
