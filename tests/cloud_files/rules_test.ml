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

let () =
  p "\n== apply state (§10.1)\n";
  let show (s : Apply_state.t) =
    Printf.sprintf "anchor %S, pending [%s]" s.anchor
      (String.concat "; " s.pending)
  in
  let s = { Apply_state.anchor = "12|3"; pending = ["d:9f3a"; "root"] } in
  p "%s -> %s\n" (Apply_state.encode s)
    (match Apply_state.decode (Apply_state.encode s) with
      | Some back when back = s -> "reads back"
      | _ -> "MISREAD");
  p "fresh: %s\n" (show Apply_state.fresh);
  List.iter
    (fun text ->
      p "%-40S %s\n" text
        (match Apply_state.decode text with
          | Some s -> show s
          | None -> "unreadable"))
    [""; "{}"; {|{"anchor":"x"}|}; {|{"anchor":"x","pending":[1]}|}; "not json"]

let () =
  p "\n== applying a folder (§10.2)\n";
  let row ?(is_dir = false) ?(is_link = false) ?(size = 5) ?(mtime = 100.)
      ?(content = "c1") ?(read_only = false) ref_ leaf : Apply_plan.row =
    {
      ref_;
      leaf;
      is_dir;
      is_link;
      size;
      mtime;
      content_id = (if is_dir then None else Some content);
      read_only;
    }
  in
  let child ?(owed = false) ?identity ?(size = 5) ?(mtime = 100.) name :
      Apply_plan.child =
    { name; owed; identity; size; mtime; read_only = false }
  in
  let id ref_ content_id = Some { Identity.ref_; content_id } in
  let show label ?(locate = fun _ -> `Not_held) rows children =
    let actions =
      Apply_plan.plan ~fold:String.uppercase_ascii ~rows ~children ~locate
    in
    p "%s\n" label;
    if actions = [] then p "  nothing\n";
    List.iter
      (fun (a : Apply_plan.action) ->
        p "  %s\n"
          (match a with
            | Take n -> "take " ^ n
            | Rename { from; to_ } -> Printf.sprintf "rename %s -> %s" from to_
            | Refresh { name; _ } -> "refresh " ^ name
            | Update { name; _ } -> "update " ^ name
            | Move { name; into; as_ } ->
                Printf.sprintf "move %s into %s as %s" name into as_
            | Delete n -> "delete " ^ n
            | Create { name; row } ->
                Printf.sprintf "create %s (%s)" name
                  (if row.is_dir then "folder" else "file")))
      actions
  in
  show "a new folder: everything is created"
    [row "i:1" "a.txt"; row ~is_dir:true "d:2" "sub"]
    [];
  show "in step: nothing"
    [row "i:1" "a.txt"; row ~is_dir:true "d:2" "sub"]
    [
      child ?identity:(id "i:1" "c1") "a.txt";
      child ?identity:(id "d:2" "") "sub";
    ];
  show "a peer renamed it"
    [row "i:1" "b.txt"]
    [child ?identity:(id "i:1" "c1") "a.txt"];
  show "a peer edited it"
    [row ~content:"c2" ~size:7 "i:1" "a.txt"]
    [child ?identity:(id "i:1" "c1") "a.txt"];
  show "a peer renamed and edited it"
    [row ~content:"c2" "i:1" "b.txt"]
    [child ?identity:(id "i:1" "c1") "a.txt"];
  show "only its time changed"
    [row ~mtime:200. "i:1" "a.txt"]
    [child ?identity:(id "i:1" "c1") "a.txt"];
  show "a row with no time is not compared on it"
    [row ~mtime:0. "i:1" "a.txt"]
    [child ~mtime:1700000000. ?identity:(id "i:1" "c1") "a.txt"];
  show "an owed child is taken, and a row of its name not created"
    [row "i:3" "notes.txt"]
    [child ~owed:true "notes.txt"];
  show "an owed edit is taken, never refreshed"
    [row ~content:"c2" "i:1" "a.txt"]
    [child ~owed:true ?identity:(id "i:1" "c1") "a.txt"];
  show "a peer deleted it" [] [child ?identity:(id "i:9" "c1") "gone.txt"];
  show "a peer moved it to a folder the root holds"
    ~locate:(fun r ->
      if r = "i:9" then `Held ("C:\\root\\sub", "gone.txt") else `Not_held)
    []
    [child ?identity:(id "i:9" "c1") "gone.txt"];
  show "a foreign item stays, and its name is not reused"
    [row "i:4" "theirs.txt"]
    [child "theirs.txt"];
  show "names Windows refuses, links and case groups are not created"
    [
      row "i:5" "a:b";
      row ~is_link:true "i:6" "link";
      row "i:7" "X";
      row "i:8" "x";
    ]
    [];
  show "the group member on disk stays"
    [row "i:7" "X"; row "i:8" "x"]
    [child ?identity:(id "i:8" "c1") "x"]
