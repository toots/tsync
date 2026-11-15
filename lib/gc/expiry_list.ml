open Tsync_core
open Tsync_store

type entry = { ns : int64; size : int option; path : string }

let gone = " (folder gone)"

let path ~folder ~name =
  match folder with Some dir -> Names.join dir name | None -> name ^ gone

let line { ns; size; path } =
  Printf.sprintf "%Ld  %s  %s  %s" ns
    (Narrate.date (Int64.to_float ns /. 1e9))
    (match size with Some s -> Narrate.size s | None -> "unreadable")
    path

let by_path a b =
  match String.compare a.path b.path with
    | 0 -> Int64.compare b.ns a.ns
    | c -> c

let print ~domain ~cutoff ~now entries =
  let b = Buffer.create 4096 in
  let add s =
    Buffer.add_string b s;
    Buffer.add_char b '\n'
  in
  add "# tsync expiry list";
  add ("# domain: " ^ Domain_name.to_string domain);
  add
    (Printf.sprintf "# versions older than %s, listed %s" (Narrate.date cutoff)
       (Narrate.date now));
  add
    "# Remove a line to keep that version. Lines starting with # and blank \
     lines are ignored.";
  List.iter (fun e -> add (line e)) (List.sort by_path entries);
  Buffer.contents b

type parsed = {
  number : int;
  ns : int64;
  folder : string option;
  name : string;
}

type listing = {
  domain : (int * string) option;
  lines : parsed list;
  malformed : (int * string) list;
}

(* The text before the first separator, and the text after it. *)
let cut s =
  let n = String.length s in
  let rec go i =
    if i + 1 >= n then None
    else if s.[i] = ' ' && s.[i + 1] = ' ' then
      Some (String.sub s 0 i, String.sub s (i + 2) (n - i - 2))
    else go (i + 1)
  in
  go 0

let parse_line number s =
  let ( let* ) = Option.bind in
  match
    let* ts, rest = cut s in
    let* _date, rest = cut rest in
    let* _size, path = cut rest in
    let* ns = Int64.of_string_opt ts in
    Some (ns, path)
  with
    | None -> Error "not a version line (time  date  size  path)"
    | Some (_, "") -> Error "no path"
    | Some (ns, path) ->
        let folder, p =
          if String.ends_with ~suffix:gone path then
            (None, String.sub path 0 (String.length path - String.length gone))
          else (Some (Names.parent_of path), path)
        in
        let name = Names.leaf_of p in
        if name = "" then Error "no file name"
        else Ok { number; ns; folder; name }

let domain_header = "# domain:"

let parse text =
  let domain = ref None and lines = ref [] and malformed = ref [] in
  List.iteri
    (fun i raw ->
      let number = i + 1 in
      let s =
        if String.ends_with ~suffix:"\r" raw then
          String.sub raw 0 (String.length raw - 1)
        else raw
      in
      if String.starts_with ~prefix:domain_header s then
        domain :=
          Some
            ( number,
              String.trim
                (String.sub s
                   (String.length domain_header)
                   (String.length s - String.length domain_header)) )
      else if String.trim s = "" || String.starts_with ~prefix:"#" s then ()
      else (
        match parse_line number s with
          | Ok l -> lines := l :: !lines
          | Error why -> malformed := (number, why) :: !malformed))
    (String.split_on_char '\n' text);
  { domain = !domain; lines = List.rev !lines; malformed = List.rev !malformed }

type resolution = {
  matched : Key.t list;
  rejected : (int * string) list;
  absent : int list;
  warnings : (int * string) list;
}

(* A version key is [versions/<folder id>/<dual digest of the name>/<ns>]
   (data-model/backend §2.9): a line resolves without reading any body. *)
let resolve ~domain ~folder_path ~versions listing =
  let prefix = Key.versions domain in
  let by_ns = Hashtbl.create 1024 in
  List.iter
    (fun k ->
      if Key.under prefix k then (
        match String.split_on_char '/' (Key.rel prefix k) with
          | [folder; digest; ns] ->
              Option.iter
                (fun ns -> Hashtbl.add by_ns ns (folder, digest, k))
                (Int64.of_string_opt ns)
          | _ -> ()))
    versions;
  let paths = Hashtbl.create 64 in
  let current folder =
    match Hashtbl.find_opt paths folder with
      | Some p -> p
      | None ->
          let p = Option.bind (Folder_id.of_string folder) folder_path in
          Hashtbl.replace paths folder p;
          p
  in
  let seen = Hashtbl.create 1024 in
  let matched = ref [] and rejected = ref [] in
  let absent = ref [] and warnings = ref [] in
  let shown = function None -> "gone" | Some "" -> "the top" | Some p -> p in
  List.iter
    (fun l ->
      match Hashtbl.find_all by_ns l.ns with
        | [] -> absent := l.number :: !absent
        | candidates -> (
            let digest = Xxh.dual l.name in
            let named =
              List.filter (fun (_, d, _) -> String.equal d digest) candidates
            in
            let here =
              List.filter (fun (f, _, _) -> current f = l.folder) named
            in
            match (named, here) with
              | [], _ ->
                  rejected :=
                    ( l.number,
                      Printf.sprintf "no version of %S at that time" l.name )
                    :: !rejected
              | [(f, _, k)], _ | _, [(f, _, k)] ->
                  if current f <> l.folder then
                    warnings :=
                      ( l.number,
                        Printf.sprintf "%s: its folder is now %s" l.name
                          (shown (current f)) )
                      :: !warnings;
                  if not (Hashtbl.mem seen k) then (
                    Hashtbl.replace seen k ();
                    matched := k :: !matched)
              | _ ->
                  rejected :=
                    ( l.number,
                      Printf.sprintf "%S at that time is in several folders"
                        l.name )
                    :: !rejected))
    listing.lines;
  let header =
    match listing.domain with
      | Some (n, other) when other <> Domain_name.to_string domain ->
          [
            ( n,
              Printf.sprintf "a list of domain %s, not %s" other
                (Domain_name.to_string domain) );
          ]
      | _ -> []
  in
  {
    matched = List.rev !matched;
    rejected = List.sort compare (header @ listing.malformed @ !rejected);
    absent = List.rev !absent;
    warnings = List.rev !warnings;
  }

module Make (C : Tsync_remote.Context.S) = struct
  module T = Tsync_remote.Tree.Make (C)

  let folder_path id =
    let rec climb id acc depth =
      if Folder_id.is_root id then Some (String.concat "/" acc)
      else if depth > 256 then None
      else (
        match T.anchor id with
          | Some a -> climb a.parent (a.aname :: acc) (depth + 1)
          | None -> None)
    in
    climb id [] 0

  let manifest key =
    Option.bind (C.store.get_opt key) (fun b ->
        Manifest.decode (Bigstring.to_string b))

  let group_folder group =
    match String.index_opt group '/' with
      | Some i -> Folder_id.of_string (String.sub group 0 i)
      | None -> None

  let entry ?folder ~ns (m : Manifest.t) =
    { ns; size = Some m.size; path = path ~folder ~name:m.name }

  (* Expired version keys as list entries; a version whose body does not read
     has no name to list it under. *)
  let entries keys =
    let prefix = Key.versions C.domain in
    let folders = Hashtbl.create 64 in
    let folder group =
      match Hashtbl.find_opt folders group with
        | Some f -> f
        | None ->
            let f = Option.bind (group_folder group) folder_path in
            Hashtbl.replace folders group f;
            f
    in
    List.fold_left
      (fun (listed, unreadable) k ->
        let group, ns = Key.split_last (Key.rel prefix k) in
        match (Int64.of_string_opt ns, manifest k) with
          | Some ns, Some m ->
              (entry ?folder:(folder group) ~ns m :: listed, unreadable)
          | _ -> (listed, k :: unreadable))
      ([], []) keys
    |> fun (listed, unreadable) -> (List.rev listed, List.rev unreadable)

  let resolve listing =
    resolve ~domain:C.domain ~folder_path
      ~versions:
        (List.map
           (fun (e : Store.entry) -> e.key)
           (C.store.list_prefix (Key.versions C.domain)))
      listing
end
