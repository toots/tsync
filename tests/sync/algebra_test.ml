(* Every triple of small trees through the merge, checked against Theorem 8,
   and every pair through the order of Theorem 3. ALGEBRA_FULL=1 adds the
   universes too large for a routine run. *)

open Tsync_core
module A = Algebra

type universe = {
  label : string;
  ids : Folder_id.t list;
  names : string list;
  contents : int list;
  max_files : int;
}

let id n = Folder_id.mint ~uuid:"aaaaaaaaaaaaaaaa" ~counter:n
let root = Folder_id.root

(* A state in full: every key of the universe that is not ∅. *)
type state = {
  files : (A.place * int) list;
  folders : (Folder_id.t * A.place) list;
}

let commands s : int A.command list =
  List.map (fun (p, v) -> `File (p, None, Some v)) s.files
  @ List.map (fun (i, p) -> `Folder (i, None, Some p)) s.folders

let build s = A.apply A.empty (commands s)
let keys s = List.map A.key_of (commands s)

(* Definition 3, written without the library. *)
let naive_well_formed s =
  let present d = Folder_id.is_root d || List.mem_assoc d s.folders in
  let places = List.map fst s.files @ List.map snd s.folders in
  let rec rooted seen i =
    Folder_id.is_root i
    || (not (List.mem i seen))
       &&
         match List.assoc_opt i s.folders with
         | Some p -> rooted (i :: seen) p.parent
         | None -> false
  in
  List.for_all (fun (p : A.place) -> present p.parent) places
  && List.length (List.sort_uniq compare places) = List.length places
  && List.for_all (fun (i, _) -> rooted [] i) s.folders

let rec choices = function
  | [] -> [[]]
  | options :: rest ->
      let tails = choices rest in
      List.concat_map (fun o -> List.map (fun t -> o :: t) tails) options

let states u =
  let places =
    List.concat_map
      (fun parent -> List.map (fun name -> { A.parent; name }) u.names)
      (root :: u.ids)
  in
  let folder_options i =
    None
    :: List.filter_map
         (fun (p : A.place) ->
           if p.parent = i then None else Some (Some (i, p)))
         places
  in
  let file_options p = None :: List.map (fun c -> Some (p, c)) u.contents in
  let folders = choices (List.map folder_options u.ids) in
  let files =
    List.filter
      (fun l -> List.length (List.filter_map Fun.id l) <= u.max_files)
      (choices (List.map file_options places))
  in
  List.concat_map
    (fun fo ->
      List.filter_map
        (fun fi ->
          let s =
            {
              files = List.filter_map Fun.id fi;
              folders = List.filter_map Fun.id fo;
            }
          in
          let ok = naive_well_formed s in
          if ok <> (A.well_formed (build s) (keys s) = Ok ()) then
            failwith "well_formed disagrees with the naive check";
          if ok then Some s else None)
        files)
    folders

let diff a b : int A.command list =
  let file s p = List.assoc_opt p s.files
  and folder s i = List.assoc_opt i s.folders in
  let places =
    List.sort_uniq compare (List.map fst a.files @ List.map fst b.files)
  and ids =
    List.sort_uniq compare (List.map fst a.folders @ List.map fst b.folders)
  in
  List.filter_map
    (fun p ->
      if file a p = file b p then None else Some (`File (p, file a p, file b p)))
    places
  @ List.filter_map
      (fun i ->
        if folder a i = folder b i then None
        else Some (`Folder (i, folder a i, folder b i)))
      ids

(* The whole of a state over [of_]'s keys and [extra]. *)
let read t ~of_ ~extra =
  let places =
    List.sort_uniq compare
      (List.concat_map (fun s -> List.map fst s.files) of_ @ extra)
  and ids =
    List.sort_uniq compare
      (List.concat_map (fun s -> List.map fst s.folders) of_)
  in
  {
    files =
      List.filter_map
        (fun p -> Option.map (fun v -> (p, v)) (A.file t p))
        places;
    folders =
      List.filter_map (fun i -> Option.map (fun p -> (i, p)) (A.folder t i)) ids;
  }

let aside ~taken ~is_dir:_ name =
  let rec go n = if taken n then go (n ^ "'") else n in
  go (name ^ "'")

let show s =
  let place (p : A.place) =
    Printf.sprintf "%s/%s"
      (if Folder_id.is_root p.parent then "" else Folder_id.to_string p.parent)
      p.name
  in
  String.concat " "
    (List.map (fun (p, v) -> Printf.sprintf "%s=%d" (place p) v) s.files
    @ List.map
        (fun (i, p) -> Printf.sprintf "%s@%s" (Folder_id.to_string i) (place p))
        s.folders)
  |> Printf.sprintf "{%s}"

let failures = Hashtbl.create 16

let fail what ~r ~l ~m ~n =
  let count = Option.value ~default:0 (Hashtbl.find_opt failures what) in
  Hashtbl.replace failures what (count + 1);
  if count < 5 then
    Printf.printf "FAIL %s: R=%s L=%s M=%s N=%s\n" what (show r) (show l)
      (show m) n

let priorities : A.rule list list =
  [
    [`R1; `R2; `R3];
    [`R1; `R3; `R2];
    [`R2; `R1; `R3];
    [`R2; `R3; `R1];
    [`R3; `R1; `R2];
    [`R3; `R2; `R1];
  ]

type tally = {
  mutable triples : int;
  mutable copies : int;
  mutable restores : int;
  mutable dropped_moves : int;
  mutable renamed : int;
}

(* A state with every fresh name read as the name it was made from. *)
let unnamed s =
  let plain (p : A.place) =
    { p with name = String.concat "" (String.split_on_char '\'' p.name) }
  in
  {
    files = List.sort compare (List.map (fun (p, v) -> (plain p, v)) s.files);
    folders =
      List.sort compare (List.map (fun (i, p) -> (i, plain p)) s.folders);
  }

let temp i = ".tmp-" ^ Folder_id.to_string i

let check_order what ~from ~to_ =
  let base = A.of_base (A.to_base (build from)) in
  let commands = diff from to_ in
  match A.order ~temp base commands with
    | exception Failure e ->
        fail (what ^ ": order raised " ^ e) ~r:from ~l:from ~m:to_ ~n:"-"
    | steps ->
        let extra =
          List.map
            (fun i -> { A.parent = root; name = temp i })
            (List.map fst (from.folders @ to_.folders))
        in
        ignore
          (List.fold_left
             (fun t step ->
               let t = A.run t [step] in
               let s = read t ~of_:[from; to_] ~extra in
               (* a parked folder is in [folders], so the naive check sees it *)
               if not (naive_well_formed s) then
                 fail
                   (what ^ ": order passes through an ill-formed tree")
                   ~r:from ~l:from ~m:to_ ~n:(show s);
               t)
             base steps);
        let reached = read (A.run base steps) ~of_:[from; to_] ~extra in
        if
          reached
          <> {
               files = List.sort compare to_.files;
               folders = List.sort compare to_.folders;
             }
        then
          fail
            (what ^ ": order does not reach its target")
            ~r:from ~l:from ~m:to_ ~n:(show reached)

(* Every subset of a difference through [take], with and without a limit:
   what it sets is a batch, and it sets something unless nothing can be. *)
let takes = ref 0

let check_take ~from ~to_ =
  let all = diff from to_ in
  let base = A.of_base (A.to_base (build from)) in
  let rec subsets = function
    | [] -> [[]]
    | c :: rest ->
        let tails = subsets rest in
        tails @ List.map (fun t -> c :: t) tails
  in
  let fail what n = fail what ~r:from ~l:from ~m:to_ ~n in
  let extra =
    List.map
      (fun i -> { A.parent = root; name = temp i })
      (List.map fst (from.folders @ to_.folders))
  in
  if List.length all <= 6 then
    List.iter
      (fun subset ->
        List.iter
          (fun limit ->
            incr takes;
            let steps, left = A.take ?limit ~temp base subset in
            let set =
              List.filter_map
                (function `Set c -> Some c | `Park _ -> None)
                steps
            in
            let reached = read (A.run base steps) ~of_:[from; to_] ~extra in
            if not (naive_well_formed reached) then
              fail "take: what it sets is not a batch" (show reached);
            if not (A.is_batch base set) then
              fail "take: is_batch disagrees" (show reached);
            if List.sort compare (set @ left) <> List.sort compare subset then
              fail "take: a command is neither set nor left" (show reached);
            if limit = None && set = [] && subset <> [] then
              if List.exists (fun c -> A.is_batch base [c]) subset then
                fail "take: sets nothing although one command alone is a batch"
                  (show reached))
          [None; Some 1; Some 2])
      (subsets all)

let check tally ~r ~l ~m =
  tally.triples <- tally.triples + 1;
  let before = diff r l and theirs = diff r m in
  let merge ?priority () =
    A.merge ?priority ~equal:Int.equal ~aside
      ~l:(A.to_base (build l))
      ~before ~theirs ()
  in
  match merge () with
    | exception Failure e -> fail ("merge raised: " ^ e) ~r ~l ~m ~n:"-"
    | merged -> (
        let extra = List.map snd merged.asides in
        let n = read merged.n ~of_:[r; l; m] ~extra in
        let fail what = fail what ~r ~l ~m ~n:(show n) in
        let file s p = List.assoc_opt p s.files
        and folder s i = List.assoc_opt i s.folders in
        if merged.asides <> [] then tally.copies <- tally.copies + 1;
        if merged.restored <> [] then tally.restores <- tally.restores + 1;
        if not (naive_well_formed n) then fail "1 well-formed";
        let sorted s =
          {
            files = List.sort compare s.files;
            folders = List.sort compare s.folders;
          }
        in
        if m = r && n <> sorted l then fail "2 identity (M = R)";
        if l = r && n <> sorted m then fail "2 identity (L = R)";
        List.iter
          (fun (p, v) ->
            if
              file n p <> Some v && not (file r p = Some v && file l p <> Some v)
            then fail "3 the main is preserved (file)")
          m.files;
        List.iter
          (fun (i, p) ->
            if
              folder n i <> Some p
              && not (folder r i = Some p && folder l i <> Some p)
            then fail "3 the main is preserved (folder)")
          m.folders;
        List.iter
          (fun ((p : A.place), v) ->
            if file r p <> Some v then (
              let kept (q : A.place) =
                q.parent = p.parent && file n q = Some v
              in
              let copy = List.assoc_opt p merged.asides in
              if not (kept p || Option.fold ~none:false ~some:kept copy) then
                fail "4 nothing local is lost"))
          l.files;
        let ours = List.map A.key_of before in
        List.iter
          (fun (c : int A.command) ->
            let k = A.key_of c in
            let made =
              match k with
                | `File p -> List.exists (fun (_, q) -> q = p) merged.asides
                | `Folder i -> List.mem i merged.restored
            in
            if not (List.mem k ours || made) then fail "5 confined")
          (diff m n);
        let pending =
          List.filter
            (fun c -> not (A.is_null ~equal:Int.equal c))
            merged.pending
        in
        if List.sort compare pending <> List.sort compare (diff m n) then
          fail "the pending set is diff(M, N)";
        List.iter
          (fun (i, p) ->
            if
              folder r i <> Some p
              && folder n i <> Some p
              && not (List.mem i merged.restored && folder m i = None)
            then tally.dropped_moves <- tally.dropped_moves + 1)
          l.folders;
        List.iter
          (fun priority ->
            match merge ~priority () with
              | exception Failure e ->
                  fail ("merge raised under another priority: " ^ e)
              | other ->
                  let other =
                    read other.n ~of_:[r; l; m]
                      ~extra:(List.map snd other.asides)
                  in
                  if other <> n then
                    if unnamed other = unnamed n then
                      tally.renamed <- tally.renamed + 1
                    else fail "the repair depends on its order")
          (List.tl priorities);
        match A.order ~temp (A.of_base (A.to_base (build l))) merged.local with
          | exception Failure e -> fail ("enacting raised: " ^ e)
          | steps ->
              let reached =
                read
                  (A.run (A.of_base (A.to_base (build l))) steps)
                  ~of_:[r; l; m] ~extra
              in
              if reached <> n then fail "enacting diff(L, N) does not reach N")

let run u =
  let all = states u in
  let tally =
    { triples = 0; copies = 0; restores = 0; dropped_moves = 0; renamed = 0 }
  in
  List.iter
    (fun from ->
      List.iter
        (fun to_ ->
          check_order u.label ~from ~to_;
          check_take ~from ~to_)
        all)
    all;
  List.iter
    (fun r ->
      List.iter (fun l -> List.iter (fun m -> check tally ~r ~l ~m) all) all)
    all;
  Printf.printf
    "%s: %d states, %d triples, %d with a copy, %d with a restored folder, %d \
     local folder places dropped, %d where the order of the repair changes a \
     fresh name\n\
     %!"
    u.label (List.length all) tally.triples tally.copies tally.restores
    tally.dropped_moves tally.renamed

let () =
  let a = id 1 and b = id 2 and c = id 3 in
  let routine =
    [
      {
        label = "one folder, two names, one file";
        ids = [a];
        names = ["x"; "y"];
        contents = [1; 2];
        max_files = 1;
      };
      {
        label = "two folders, one name, one file";
        ids = [a; b];
        names = ["x"];
        contents = [1; 2];
        max_files = 1;
      };
      {
        label = "three folders, one name";
        ids = [a; b; c];
        names = ["x"];
        contents = [];
        max_files = 0;
      };
    ]
  and full =
    [
      {
        label = "two folders, two names, one file";
        ids = [a; b];
        names = ["x"; "y"];
        contents = [1; 2];
        max_files = 1;
      };
      {
        label = "one folder, two names, two files";
        ids = [a];
        names = ["x"; "y"];
        contents = [1; 2];
        max_files = 2;
      };
      {
        label = "three folders, two names";
        ids = [a; b; c];
        names = ["x"; "y"];
        contents = [];
        max_files = 0;
      };
    ]
  in
  List.iter run
    (routine @ if Sys.getenv_opt "ALGEBRA_FULL" = None then [] else full);
  Printf.printf "%d subsets of a difference taken as a batch\n" !takes;
  if Hashtbl.length failures = 0 then print_endline "every property holds"
  else
    Hashtbl.iter
      (fun what count -> Printf.printf "%d × %s\n" count what)
      failures
