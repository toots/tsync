open Tsync_core

let read (store : Store.t) d =
  match store.get_opt (Key.gc_generation d) with
    | None -> Some 0
    | Some b -> (
        match Yojson.Safe.from_string (Bigstring.to_string b) with
          | `Assoc f -> (
              match List.assoc_opt "generation" f with
                | Some (`Int g) when g >= 0 -> Some g
                | _ -> None)
          | _ -> None
          | exception _ -> None)

let read_mains stores d =
  List.fold_left
    (fun acc store ->
      match acc with
        | None -> None
        | Some g -> (
            match read store d with
              | Some g' -> Some (max g g')
              | None -> None
              | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
              | exception _ -> None))
    (Some 0) stores

let encode g =
  Bigstring.of_string (Yojson.Safe.to_string (`Assoc [("generation", `Int g)]))

let write (store : Store.t) d g = store.put (Key.gc_generation d) (encode g)

let settle store d ~owed =
  match read store d with
    | Some g when g mod 2 = 1 && owed g = 0 ->
        write store d (g + 1);
        Log.info "collection generation %d settled" g
    | _ -> ()
