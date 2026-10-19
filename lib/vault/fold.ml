open Tsync_core

type file = { name : string; body : string }

type action =
  | Move of { src : string; dst : string }
  | Remove of string
  | Write of { name : string; body : string }

let is_record_id s = String.length s = 32 && String.for_all Names.is_hexlower s
let copy_marker = " (conflicted copy "

(* conflict-resolution §5: a leaf with no extension gets the marker appended. *)
let base_of name =
  let n = String.length name and m = String.length copy_marker in
  let rec find i =
    if i + m > n then None
    else if String.sub name i m = copy_marker then Some (String.sub name 0 i)
    else find (i + 1)
  in
  if String.ends_with ~suffix:")" name then find 0 else None

(* conflict-resolution §5: "<base> (conflicted copy[ n] from <client>)". *)
let copied_from name =
  Option.bind (base_of name) (fun base ->
      let rest =
        String.sub name (String.length base)
          (String.length name - String.length base)
      in
      let marker = " from " in
      let n = String.length rest and m = String.length marker in
      let rec find i =
        if i + m > n then None
        else if String.sub rest i m = marker then
          Some (String.sub rest (i + m) (n - i - m - 1))
        else find (i + 1)
      in
      find 0)

let groups files =
  let by = Hashtbl.create 16 in
  List.iter
    (fun f ->
      let base =
        if is_record_id f.name then Some f.name
        else
          Option.bind (base_of f.name) (fun b ->
              if is_record_id b then Some b else None)
      in
      Option.iter
        (fun b ->
          Hashtbl.replace by b
            (f :: Option.value ~default:[] (Hashtbl.find_opt by b)))
        base)
    files;
  List.sort compare (List.of_seq (Hashtbl.to_seq_keys by))
  |> List.map (fun b -> (b, List.rev (Hashtbl.find by b)))

let digest_id body =
  Xxh.hex16 (Xxh.string ~seed:0L body) ^ Xxh.hex16 (Xxh.string ~seed:1L body)

(* README §4.3 rule 3: newest, then bytewise greatest. *)
let greatest ~modified members =
  List.fold_left
    (fun best (f, r) ->
      match best with
        | None -> Some (f, r)
        | Some (bf, br) ->
            let c = compare (modified r) (modified br) in
            if c > 0 || (c = 0 && String.compare f.body bf.body > 0) then
              Some (f, r)
            else best)
    None members
  |> Option.get

(* One kept file per group: the rest of the group is removed, the kept one
   moved to [dst] unless it is there. *)
let settle ~modified ~dst members =
  let kept, _ = greatest ~modified members in
  List.filter_map
    (fun (f, _) ->
      if f == kept then None
      else if f.name = dst then None
      else Some (Remove f.name))
    members
  @ if kept.name = dst then [] else [Move { src = kept.name; dst }]

let grouped_one ~open_ ~key ~modified ~id files =
  let opened =
    List.filter_map (fun f -> Option.map (fun r -> (f, r)) (open_ f)) files
  in
  let at_id = List.find_opt (fun f -> f.name = id) files in
  let by_key = Hashtbl.create 4 in
  List.iter
    (fun (f, r) ->
      let k = key r in
      Hashtbl.replace by_key k
        ((f, r) :: Option.value ~default:[] (Hashtbl.find_opt by_key k)))
    opened;
  let keys = List.sort compare (List.of_seq (Hashtbl.to_seq_keys by_key)) in
  let group k = List.rev (Hashtbl.find by_key k) in
  let primary =
    match at_id with
      | Some f -> (
          match List.find_opt (fun (g, _) -> g == f) opened with
            | Some (_, r) -> Some (key r)
            | None -> None)
      | None -> (
          match opened with
            | [] -> None
            | _ -> Some (key (snd (greatest ~modified opened))))
  in
  List.concat_map
    (fun k ->
      let members = group k in
      if Some k = primary then settle ~modified ~dst:id members
      else (
        let kept, _ = greatest ~modified members in
        settle ~modified ~dst:(digest_id kept.body) members))
    keys

(* A record id with no copy is settled already: nothing to open. *)
let grouped ~open_ ~key ~modified files =
  List.concat_map
    (fun (id, members) ->
      match members with
        | [f] when f.name = id -> []
        | _ -> grouped_one ~open_ ~key ~modified ~id members)
    (groups files)

let keyring ~name files =
  let copies = List.filter (fun f -> base_of f.name = Some name) files in
  match (List.find_opt (fun f -> f.name = name) files, copies) with
    | _, [] | None, _ -> ([], [])
    | Some current, _ -> (
        match Keyring.of_string current.body with
          | Error _ -> ([], List.map (fun f -> f.name) copies)
          | Ok k ->
              let merged, others =
                List.fold_left
                  (fun (acc, others) c ->
                    match Keyring.of_string c.body with
                      | Ok ck -> (
                          match Keyring.union acc ck with
                            | Some u -> (u, others)
                            | None -> (acc, c.name :: others))
                      | Error _ -> (acc, c.name :: others))
                  (k, []) copies
              in
              let folded =
                List.filter (fun c -> not (List.mem c.name others)) copies
              in
              let body = Keyring.to_string merged in
              ( (if body = current.body || folded = [] then []
                 else [Write { name; body }])
                @ List.map (fun c -> Remove c.name) folded,
                List.rev others ))
