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
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then (
      match (s.[i], String.index_from_opt s i ';') with
        | '&', Some j -> (
            let entity = String.sub s (i + 1) (j - i - 1) in
            let code =
              match entity with
                | "amp" -> Some 0x26
                | "lt" -> Some 0x3C
                | "gt" -> Some 0x3E
                | "quot" -> Some 0x22
                | "apos" -> Some 0x27
                | _ when String.starts_with ~prefix:"#x" entity ->
                    int_of_string_opt ("0x" ^ String.sub entity 2 (j - i - 3))
                | _ when String.starts_with ~prefix:"#" entity ->
                    int_of_string_opt (String.sub entity 1 (j - i - 2))
                | _ -> None
            in
            match code with
              | Some c when Uchar.is_valid c ->
                  Buffer.add_utf_8_uchar b (Uchar.of_int c);
                  go (j + 1)
              | _ ->
                  Buffer.add_char b '&';
                  go (i + 1))
        | c, _ ->
            Buffer.add_char b c;
            go (i + 1))
  in
  go 0;
  Buffer.contents b

let safe s =
  String.for_all
    (fun c -> Char.code c >= 0x20 || c = '\t' || c = '\n' || c = '\r')
    s

let delete_body keys =
  "<Delete><Quiet>true</Quiet>"
  ^ String.concat ""
      (List.map (fun k -> "<Object><Key>" ^ escape k ^ "</Key></Object>") keys)
  ^ "</Delete>"

let between s a b from =
  match Text.find_from s a from with
    | None -> None
    | Some i -> (
        let i = i + String.length a in
        match Text.find_from s b i with
          | Some j -> Some (String.sub s i (j - i), j + String.length b)
          | None -> None)

let elements body tag =
  let rec go from acc =
    match between body ("<" ^ tag ^ ">") ("</" ^ tag ^ ">") from with
      | None -> List.rev acc
      | Some (e, next) -> go next (e :: acc)
  in
  go 0 []

let field e tag =
  Option.map
    (fun (v, _) -> unescape v)
    (between e ("<" ^ tag ^ ">") ("</" ^ tag ^ ">") 0)

let delete_errors body =
  List.map
    (fun e ->
      let get t = Option.value ~default:"" (field e t) in
      (get "Code", get "Key"))
    (elements body "Error")
