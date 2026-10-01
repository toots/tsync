open Tsync_core

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | '\'' -> Buffer.add_string b "&apos;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let unescape s =
  List.fold_left
    (fun s (sub, by) -> Text.replace_all ~sub ~by s)
    s
    [
      ("&lt;", "<");
      ("&gt;", ">");
      ("&quot;", "\"");
      ("&apos;", "'");
      ("&amp;", "&");
    ]

let safe s =
  String.for_all
    (fun c -> Char.code c >= 0x20 || c = '\t' || c = '\n' || c = '\r')
    s

let delete_body keys =
  "<Delete><Quiet>true</Quiet>"
  ^ String.concat ""
      (List.map (fun k -> "<Object><Key>" ^ escape k ^ "</Key></Object>") keys)
  ^ "</Delete>"

let delete_errors body =
  let between s a b from =
    match Text.find_from s a from with
      | None -> None
      | Some i -> (
          let i = i + String.length a in
          match Text.find_from s b i with
            | Some j -> Some (String.sub s i (j - i), j + String.length b)
            | None -> None)
  in
  let rec go from acc =
    match between body "<Error>" "</Error>" from with
      | None -> List.rev acc
      | Some (e, next) ->
          let field t =
            Option.fold ~none:"" ~some:fst
              (between e ("<" ^ t ^ ">") ("</" ^ t ^ ">") 0)
          in
          go next ((field "Code", unescape (field "Key")) :: acc)
  in
  go 0 []
