(* The Windows host's pure rules (cloud-files §4.3, §7, §8.1). *)

open Tsync_core
open Tsync_cloud_files_rules

let p fmt = Printf.printf fmt

let () =
  p "== presentable (§7.1)\n";
  List.iter
    (fun leaf ->
      let label =
        if String.length leaf > 24 then
          Printf.sprintf "<%d bytes>" (String.length leaf)
        else Printf.sprintf "%S" leaf
      in
      p "%-28s %s\n" label
        (match Presentation.presentable leaf with
          | Ok name when name = leaf -> "shown"
          | Ok name -> Printf.sprintf "shown as %S" name
          | Error why -> why))
    [
      "notes.txt";
      "a:b";
      "a?";
      "pipe|";
      "tab\there";
      "trailing.";
      "trailing ";
      "CON";
      "con.txt";
      "Com1.log";
      "COM\xc2\xb9";
      "LPT0";
      "CONSOLE";
      "conx.txt";
      ".hidden";
      "caf\xc3\xa9";
      "bad\xffbyte";
      String.make 255 'a';
      String.make 256 'a';
      String.concat "" (List.init 127 (fun _ -> "\xf0\x9f\x98\x80"));
      String.concat "" (List.init 128 (fun _ -> "\xf0\x9f\x98\x80"));
    ]

let () =
  p "\n== case groups (§7.2)\n";
  let show label ~on_disk children =
    let presented, others =
      Presentation.choose ~fold:String.uppercase_ascii
        ~on_disk:(fun n -> List.mem n on_disk)
        (List.map (fun l -> (l, l)) children)
    in
    p "%s\n  shown: %s\n" label (String.concat ", " (List.map snd presented));
    List.iter
      (fun (leaf, why) ->
        p "  not shown: %s, %s\n" leaf
          (match why with
            | `Unpresentable r -> r
            | `Case_group w -> "the group shows " ^ w))
      others
  in
  show "none on disk: the least by bytes" ~on_disk:[]
    ["readme"; "README"; "Readme"; "other"];
  show "the one on disk stays" ~on_disk:["readme"]
    ["README"; "readme"; "Readme"];
  show "unpresentable and grouped together" ~on_disk:[] ["a."; "x"; "X"; "a"]

let () =
  p "\n== identity (§8.1)\n";
  List.iter
    (fun (t : Identity.t) ->
      let s = Identity.encode t in
      p "%S -> %s\n" s
        (match Identity.decode s with
          | Some back when back = t -> "reads back"
          | _ -> "MISREAD"))
    [
      { ref_ = "d:9f3a"; content_id = "" };
      { ref_ = "i:6c1e"; content_id = "0123456789abcdef-fedcba9876543210" };
    ];
  List.iter
    (fun s ->
      p "%S -> %s\n" s
        (match Identity.decode s with Some _ -> "read" | None -> "foreign"))
    [""; "t2\ni:1\nx"; "t1\n\nx"; "t1\ni:1"; "t1\ni:1\nx\nextra"; "OneDrive"]

let () =
  p "\n== sync root id (§4.3)\n";
  let sid = "S-1-5-21-1-2-3-1001" in
  p "prefix %s\n" (Sync_root_id.prefix ~sid);
  List.iter
    (fun name ->
      let id = Sync_root_id.id ~sid (Domain_name.v name) in
      p "%-12s %s (under the prefix %b)\n" name id
        (String.starts_with ~prefix:(Sync_root_id.prefix ~sid) id))
    ["docs"; "Docs"; "a!b:c"]
