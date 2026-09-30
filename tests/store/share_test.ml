module S = Tsync_http_proxy.Share_server

let p fmt = Printf.printf (fmt ^^ "\n")

let () =
  p "== ranges of a 39-byte file (§A9.5)";
  List.iter
    (fun h ->
      p "%-16s %s"
        (Option.value ~default:"(none)" h)
        (match S.parse_range 39 h with
          | `Whole -> "whole"
          | `Unsatisfiable -> "416"
          | `Range (a, b) -> Printf.sprintf "bytes %d-%d/39" a b))
    [
      None;
      Some "bytes=6-10";
      Some "bytes=6-";
      Some "bytes=-5";
      Some "bytes=-100";
      Some "bytes=30-100";
      Some "bytes=39-";
      Some "bytes=10-6";
      Some "bytes=1-2,4-5";
      Some "bytes=+1-2";
      Some "items=1-2";
      Some "bytes=-0";
    ];
  p "== content-disposition (security §13)";
  p "%s" (S.disposition "attachment" "report.pdf");
  p "%s" (S.disposition "inline" "a\"b\\c ✓\n.txt");
  p "== single-pass templating";
  p "%s" (S.fill "<h1>__A__</h1> __B__" [("__A__", "__B__"); ("__B__", "b")]);
  p "== JSON inside a script";
  p "%s"
    (S.script_json (`Assoc [("title", `String "</script><b>&\xe2\x80\xa8")]))
