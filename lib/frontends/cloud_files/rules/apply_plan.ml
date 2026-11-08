type row = {
  ref_ : string;
  leaf : string;
  is_dir : bool;
  is_link : bool;
  size : int;
  times : Tsync_core.Fs.times;
  content_id : string option;
  read_only : bool;
}

type child = {
  name : string;
  owed : bool;
  identity : Identity.t option;
  size : int;
  times : Tsync_core.Fs.times;
  read_only : bool;
}

type elsewhere = [ `Held of string * string | `Not_held ]

type action =
  | Take of string
  | Rename of { from : string; to_ : string }
  | Refresh of { name : string; row : row }
  | Update of { name : string; row : row }
  | Move of { name : string; into : string; as_ : string }
  | Delete of string
  | Create of { name : string; row : row }

(* §8.2: a row with no time gave its placeholder the time it was made, which
   is not compared; a placeholder holds a time to 100 ns. *)
let metadata_differs (c : child) (row : row) =
  let apart a b = abs (a - b) >= 100 in
  (not row.is_dir)
  && (c.size <> row.size
     || row.times.mtime > 0
        && (apart c.times.mtime row.times.mtime
           || apart c.times.created
                (Tsync_core.Fs.creation ~mtime:row.times.mtime row.times.created)
           )
     || c.read_only <> row.read_only)

let content_differs (id : Identity.t) (row : row) =
  (not row.is_dir) && row.content_id <> Some id.content_id

let plan ~fold ~rows ~children ~locate =
  let on_disk = Hashtbl.create 16 in
  List.iter (fun (c : child) -> Hashtbl.replace on_disk c.name ()) children;
  let presented, _ =
    Presentation.choose ~fold ~on_disk:(Hashtbl.mem on_disk)
      (List.filter_map
         (fun (r : row) -> if r.is_link then None else Some (r.leaf, r))
         rows)
  in
  let by_ref = Hashtbl.create 16 in
  List.iter
    (fun ((r : row), name) -> Hashtbl.replace by_ref r.ref_ (r, name))
    presented;
  let taken_by_another (c : child) name =
    List.exists (fun (o : child) -> o != c && fold o.name = fold name) children
  in
  let held = Hashtbl.create 16 and placed = Hashtbl.create 16 in
  let hold name = Hashtbl.replace held (fold name) () in
  let child_actions (c : child) =
    match c.identity with
      | _ when c.owed ->
          hold c.name;
          [Take c.name]
      | None ->
          hold c.name;
          []
      | Some id -> (
          match Hashtbl.find_opt by_ref id.ref_ with
            | Some (row, name) when taken_by_another c name ->
                (* conflict-resolution F11: an item never lands on a name
                   another holds; it goes, as only an item matching the
                   domain may, and comes back once the name is free. *)
                Hashtbl.replace placed row.ref_ ();
                hold name;
                [Delete c.name]
            | Some (row, name) ->
                Hashtbl.replace placed row.ref_ ();
                hold name;
                (if name <> c.name then [Rename { from = c.name; to_ = name }]
                 else [])
                @
                if content_differs id row then [Refresh { name; row }]
                else if metadata_differs c row then [Update { name; row }]
                else []
            | None -> (
                match locate id.ref_ with
                  | `Held (into, as_) -> [Move { name = c.name; into; as_ }]
                  | `Not_held -> [Delete c.name]))
  in
  let changes = List.concat_map child_actions children in
  let creations =
    List.filter_map
      (fun ((row : row), name) ->
        if Hashtbl.mem placed row.ref_ || Hashtbl.mem held (fold name) then None
        else Some (Create { name; row }))
      presented
  in
  changes @ creations
