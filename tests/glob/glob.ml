let ok pat str expected =
  let g = Glob.of_pattern pat in
  let got = Glob.matches g str in
  if got <> expected then (
    Printf.eprintf "FAIL: matches %S %S → expected %b, got %b\n" pat str
      expected got;
    exit 1)

let () =
  (* literal characters including special ones *)
  ok "lost+found" "lost+found" true;
  ok "lost+found" "lost-found" false;
  ok "foo.bar" "foo.bar" true;
  ok "foo.bar" "fooXbar" false;

  (* * does not cross / *)
  ok "*.ml" "foo.ml" true;
  ok "*.ml" "dir/foo.ml" false;
  ok "src/*.ml" "src/foo.ml" true;
  ok "src/*.ml" "src/sub/foo.ml" false;

  (* ? matches one char, not / *)
  ok "fo?" "foo" true;
  ok "fo?" "fo" false;
  ok "fo?" "fo/" false;

  (* ** crosses / *)
  ok "**/.git" ".git" true;
  ok "**/.git" "a/.git" true;
  ok "**/.git" "a/b/.git" true;
  ok "**/.git" "a/b/c" false;
  ok "src/**/*.ml" "src/foo.ml" true;
  ok "src/**/*.ml" "src/a/b/foo.ml" true;
  ok "src/**/*.ml" "src/a/b/foo.c" false;

  (* basename matching used by excluded() in import.ml *)
  ok "node_modules" "node_modules" true;
  ok "*.tmp" "scratch.tmp" true;
  ok "*.tmp" "scratch.txt" false;

  (* empty pattern / empty string edge cases *)
  ok "" "" true;
  ok "" "x" false;
  ok "*" "" true;
  ok "*" "abc" true;
  ok "**" "" true;
  ok "**" "a/b/c" true;

  print_endline "ok"
