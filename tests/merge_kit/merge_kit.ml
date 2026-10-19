(* format-merge §7: the suitability properties every fold-shaped format must
   show, derived from the format's fixture. A folder is a list of files; a
   fold's actions are applied to it in memory. *)
module Fold = Tsync_vault.Fold

(** What only the format knows (§7). *)
module type FOLD_FIXTURE = sig
  type record

  val name : string

  (** The format's pure function, as registered. *)
  val fold : Fold.file list -> Fold.action list

  (** A valid record from a seed. *)
  val generate : seed:int -> record

  (** An edit the fold settles into one record: the newer wins. *)
  val mergeable : seed:int -> record -> record

  (** An edit the fold must keep apart from the original. *)
  val conflicting : seed:int -> record -> record

  (** The file of a record at a leaf. *)
  val file : name:string -> record -> Fold.file

  (** A file read back; [None] when it does not open. *)
  val read : Fold.file -> record option

  (** What must survive of a record: equal for the same change. *)
  val change : record -> string

  (** For the scale property: record counts, and the seconds and the heap growth
      in MiB each must settle within. *)
  val scale : (int * float * int) list
end

let apply files actions =
  List.fold_left
    (fun files -> function
      | Fold.Move { src; dst } -> (
          match List.find_opt (fun (f : Fold.file) -> f.name = src) files with
            | Some f ->
                { f with name = dst }
                :: List.filter
                     (fun (g : Fold.file) -> g.name <> src && g.name <> dst)
                     files
            | None -> files)
      | Remove name -> List.filter (fun (f : Fold.file) -> f.name <> name) files
      | Write { name; body } ->
          { Fold.name; body }
          :: List.filter (fun (f : Fold.file) -> f.name <> name) files)
    files actions

let sorted files =
  List.sort compare (List.map (fun (f : Fold.file) -> (f.name, f.body)) files)

(* The folder as a fold leaves it. *)
let settle fold files = apply files (fold files)
let copy id client = Printf.sprintf "%s (conflicted copy from %s)" id client
let id n = Printf.sprintf "%032x" n

module Make (F : FOLD_FIXTURE) = struct
  let changes files =
    List.sort compare
      (List.filter_map (fun f -> Option.map F.change (F.read f)) files)

  (* A record id with a mergeable copy and a conflicting one, per seed. *)
  let clash seed =
    let base = F.generate ~seed in
    let rid = id seed in
    [
      F.file ~name:rid base;
      F.file ~name:(copy rid "laptop") (F.mergeable ~seed base);
      F.file ~name:(copy rid "phone") (F.conflicting ~seed base);
    ]

  let folder n = List.concat_map clash (List.init n (fun i -> i + 1))

  let check what ok =
    Printf.printf "%-12s %-50s %s\n" F.name what (if ok then "yes" else "NO")

  let order () =
    let files = folder 4 in
    let a = sorted (settle F.fold files)
    and b = sorted (settle F.fold (List.rev files)) in
    check "the result does not depend on file order"
      (List.map fst a = List.map fst b
      && changes (settle F.fold files)
         = changes (settle F.fold (List.rev files)))

  let idempotence () =
    let once = settle F.fold (folder 4) in
    check "settling the result again changes nothing" (F.fold once = [])

  let kept () =
    let seed = 7 in
    let base = F.generate ~seed in
    let after = settle F.fold (clash seed) in
    let left = changes after in
    check "the newer of two mergeable edits replaces the older"
      (List.mem (F.change (F.mergeable ~seed base)) left
      && not (List.mem (F.change base) left));
    check "no conflicted copy is left"
      (not
         (List.exists
            (fun (f : Fold.file) -> Fold.copied_from f.name <> None)
            after));
    check "two conflicting edits are both kept"
      (List.mem (F.change (F.conflicting ~seed base)) left
      && List.length left = 2)

  let convergence () =
    let files = folder 3 in
    let a = settle F.fold files and b = settle F.fold (List.rev files) in
    check "two clients settling one state converge"
      (changes a = changes b
      && List.map fst (sorted a) = List.map fst (sorted b)
      && F.fold b = [])

  let scale () =
    List.iter
      (fun (n, budget, mib) ->
        let files = folder n in
        Gc.compact ();
        let before = (Gc.quick_stat ()).top_heap_words
        and start = Unix.gettimeofday () in
        ignore (settle F.fold files);
        let seconds = Unix.gettimeofday () -. start in
        let grown =
          ((Gc.quick_stat ()).top_heap_words - before)
          * (Sys.word_size / 8) / (1 lsl 20)
        in
        check
          (Printf.sprintf "%d clashes settle within %g s and %d MiB" n budget
             mib)
          (seconds <= budget && grown <= mib))
      F.scale

  let run () =
    order ();
    idempotence ();
    kept ();
    convergence ();
    scale ()
end
