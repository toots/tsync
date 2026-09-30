open Tsync_core
open Tsync_store

let p fmt = Printf.printf fmt
let domain = ref "d"

let k rel =
  Key.v (Text.replace_all ~sub:"tsync/d/" ~by:("tsync/" ^ !domain ^ "/") rel)

let prefix rel =
  Key.prefix
    (Text.replace_all ~sub:"tsync/d/" ~by:("tsync/" ^ !domain ^ "/") rel)

let show = function Some s -> Printf.sprintf "%S" s | None -> "none"

(* The contract's literals cross the store as bigstrings. *)
let bs = Bigstring.of_string
let str = Option.map Bigstring.to_string
let put (s : Store.t) key v = s.put key (bs v)
let get (s : Store.t) key = str (s.get_opt key)
let range (s : Store.t) key o l = str (s.get_range key o l)

let claim (s : Store.t) key v =
  match s.put_if_absent key (bs v) with
    | Store.Won -> `Won
    | Held b -> `Held (Bigstring.to_string b)

let kind_of f =
  match f () with
    | _ -> "ok"
    | exception Fail.E fl -> Fail.kind_name fl.kind
    | exception e -> Printexc.to_string e

(* The generic store conformance of spec 06 §10, printed for a snapshot. Keys
   live under [tsync/<domain>/], which the output never shows. *)
let run ?(domain_name = "d") (s : Store.t) =
  domain := domain_name;
  p "== round trips\n";
  put s (k "tsync/d/a") "hello";
  p "get_opt a: %s; absent: %s; get absent: %s\n"
    (show (get s (k "tsync/d/a")))
    (show (get s (k "tsync/d/zz")))
    (kind_of (fun () -> Store.get s (k "tsync/d/zz")));
  p "head a size: %s\n"
    (match s.head_opt (k "tsync/d/a") with
      | Some e -> string_of_int e.size
      | None -> "none");
  let big =
    String.init (8 * 1024 * 1024) (fun i -> Char.chr (i * 7 land 255))
  in
  put s (k "tsync/d/big") big;
  p "chunk-sized body identical: %b\n" (get s (k "tsync/d/big") = Some big);
  s.copy (k "tsync/d/a") (k "tsync/d/a-copy");
  p "copy: %s; copy of absent: %s\n"
    (show (get s (k "tsync/d/a-copy")))
    (kind_of (fun () -> s.copy (k "tsync/d/zz") (k "tsync/d/zz2")));
  p "\n== ranges\n";
  put s (k "tsync/d/r") "0123456789";
  List.iter
    (fun (o, l) -> p "[%d,+%d) %s\n" o l (show (range s (k "tsync/d/r") o l)))
    [(0, 3); (4, 2); (7, 3); (0, 10); (7, 100); (10, 5); (20, 1)];
  p "absent: %s; length 0: %s\n"
    (show (range s (k "tsync/d/zz") 0 1))
    (kind_of (fun () -> range s (k "tsync/d/r") 0 0));
  p "\n== claims\n";
  let results =
    Rt.map_concurrently
      (fun i -> claim s (k "tsync/d/claim") (Printf.sprintf "body-%d" i))
      [1; 2; 3; 4; 5]
  in
  let won = List.length (List.filter (( = ) `Won) results) in
  let stored = Option.get (get s (k "tsync/d/claim")) in
  let told_holder =
    List.for_all (function `Won -> true | `Held b -> b = stored) results
  in
  p "five racing claims: %d won, losers told the holder: %b\n" won told_holder;
  p "later claim: %s\n"
    (match claim s (k "tsync/d/claim") "late" with
      | `Won -> "won"
      | `Held b -> "held " ^ string_of_bool (b = stored));
  p "same body again: %s\n"
    (match claim s (k "tsync/d/claim") stored with
      | `Won -> "won"
      | `Held _ -> "held");
  p "free name: %s\n"
    (match claim s (k "tsync/d/free") "x" with
      | `Won -> "won"
      | `Held _ -> "held");
  p "\n== delete\n";
  let first = s.delete (k "tsync/d/free") in
  let second = s.delete (k "tsync/d/free") in
  p "delete: %b then %b\n" first second;
  let keys = List.init 2100 (fun i -> k (Printf.sprintf "tsync/d/m/%05d" i)) in
  let survivors = [0; 999; 1000; 1001; 2099] in
  List.iter (fun i -> put s (List.nth keys i) "x") survivors;
  s.delete_multi keys;
  p "delete_multi over 2100 keys, survivors left: %d\n"
    (List.length
       (List.filter (fun i -> get s (List.nth keys i) <> None) survivors));
  p "\n== awkward keys\n";
  let awkward = ["tsync/d/x/& < > \" ' + % # ? space"; "tsync/d/x/élan ✓"] in
  List.iter (fun key -> put s (k key) (Key.to_string (k key))) awkward;
  List.iter
    (fun key ->
      p "%S round-trips: %b\n" key (get s (k key) = Some (Key.to_string (k key))))
    awkward;
  p "listed: %b\n"
    (List.map
       (fun (e : Store.entry) -> Key.to_string e.key)
       (s.list_prefix (prefix "tsync/d/x/"))
    = List.sort compare (List.map (fun key -> Key.to_string (k key)) awkward));
  s.delete_multi (List.map k awkward);
  p "after delete_multi: %d listed\n"
    (List.length (s.list_prefix (prefix "tsync/d/x/")));
  p "invalid keys refused before anything: %s\n"
    (String.concat " "
       (List.map
          (fun key -> kind_of (fun () -> k key))
          ["tsync/../x"; "tsync/./x"; "tsync//x"; "/tsync/x"; "tsync/x/"]));
  p "\n== listing\n";
  List.iter
    (fun i -> put s (k (Printf.sprintf "tsync/d/l/%c" i)) "")
    ['c'; 'a'; 'b'; 'e'; 'd'];
  let names l =
    String.concat "," (List.map (fun (e : Store.entry) -> Key.leaf e.key) l)
  in
  p "all: %s\n" (names (s.list_prefix (prefix "tsync/d/l/")));
  p "max_keys 2: %s\n" (names (s.list_prefix ~max_keys:2 (prefix "tsync/d/l/")));
  p "empty prefix: %d\n"
    (List.length (s.list_prefix (prefix "tsync/d/nothing/")));
  p "\n== capabilities\n";
  let c = s.capabilities (Key.domain_prefix (Domain_name.v !domain)) in
  p "verified %b, share_url %s\n" c.verified (show c.share_url)

(* Everything a run left under its domain. *)
let cleanup (s : Store.t) =
  s.delete_multi
    (List.map
       (fun (e : Store.entry) -> e.key)
       (s.list_prefix (prefix "tsync/d/")))
