(* The body of a corruption marker. The marker's own key already carries the
   whole finding — a chunk is named by its bytes, so an object filed under
   [corrupted/<shard>/<key>] is one whose body did not hash to [key] — and this
   is only what an operator wants next: what it hashed to instead, how big it
   was, and when anyone last looked.

   Written by whatever took the write: this client for a local store, the
   bucket's function for s3 and gcs. So the codec is lenient in both directions —
   a marker from a newer writer, or one truncated by a crash mid-write, still
   reads as a marker, because the fact that it exists is the part that matters
   and the fields are decoration. *)

type t = { computed : string option; size : int option; at : float option }

let empty = { computed = None; size = None; at = None }

let to_string { computed; size; at } =
  Yojson.Safe.to_string
    (`Assoc
       (List.filter_map Fun.id
          [
            Option.map (fun c -> ("computed", `String c)) computed;
            Option.map (fun s -> ("size", `Int s)) size;
            Option.map (fun a -> ("at", `Float a)) at;
          ]))

(* Never raises: a body nobody can parse still came from a store that filed this
   key as corrupt, and dropping the entry would report the chunk as healthy. *)
let of_string body =
  match Yojson.Safe.from_string body with
    | exception _ -> empty
    | json ->
        let member name =
          match json with
            | `Assoc fields -> List.assoc_opt name fields
            | _ -> None
        in
        {
          computed =
            (match member "computed" with
              | Some (`String s) -> Some s
              | _ -> None);
          size =
            (match member "size" with Some (`Int n) -> Some n | _ -> None);
          at =
            (match member "at" with
              | Some (`Float f) -> Some f
              | Some (`Int n) -> Some (float_of_int n)
              | _ -> None);
        }
