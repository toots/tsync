let chunk_size = 8 * 1024 * 1024

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

type t = {
  v : int;
  size : int64;
  chunk_size : int;
  chunks : chunk_entry list;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

type state = [ `Dirty | `Clean of t ]

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

let make ~h1 ~h2 ~size ~chunk_size ~chunks ~mtime =
  `Clean { v = 1; size; chunk_size; chunks; h1; h2; mtime; symlink = None }

(* A symlink is a chunkless manifest carrying its target. size is the target's
   byte length, POSIX-style. *)
let make_symlink ~target ~mtime =
  let h1 = Xxhash.hash_hex target 0 in
  let h2 = Xxhash.hash_hex target 1 in
  `Clean
    {
      v = 1;
      size = Int64.of_int (String.length target);
      chunk_size;
      chunks = [];
      h1;
      h2;
      mtime;
      symlink = Some target;
    }

let of_json json =
  let open Yojson.Basic.Util in
  if try json |> member "dirty" |> to_bool with _ -> false then `Dirty
  else (
    (* A malformed chunk list must fail the parse: defaulting to [] would make
       a corrupt manifest read as a clean, chunkless file and download as
       zero-filled bytes of the stated size. Real files always have >= 1 chunk
       (even empty ones); only symlink manifests are legitimately chunkless. *)
    let chunks =
      json |> member "chunks" |> to_list
      |> List.map (fun c ->
          {
            index = c |> member "index" |> to_int;
            h1 = c |> member "h1" |> to_string;
            h2 = c |> member "h2" |> to_string;
            size = c |> member "size" |> to_int;
          })
    in
    let symlink =
      match json |> member "symlink" with `String s -> Some s | _ -> None
    in
    if chunks = [] && symlink = None then failwith "manifest: empty chunk list";
    `Clean
      {
        v = (try json |> member "v" |> to_int with _ -> 1);
        size = json |> member "size" |> to_int |> Int64.of_int;
        chunk_size =
          (try json |> member "chunkSize" |> to_int with _ -> chunk_size);
        chunks;
        h1 = (try json |> member "h1" |> to_string with _ -> "");
        h2 = (try json |> member "h2" |> to_string with _ -> "");
        mtime = json |> member "mtime" |> to_float;
        symlink;
      })

let of_string s = of_json (Yojson.Basic.from_string s)

let to_json = function
  | `Dirty -> `Assoc [("dirty", `Bool true)]
  | `Clean m ->
      `Assoc
        ([
           ("v", `Int m.v);
           ("size", `Int (Int64.to_int m.size));
           ("chunkSize", `Int m.chunk_size);
           ("h1", `String m.h1);
           ("h2", `String m.h2);
           ("mtime", `Float m.mtime);
           ( "chunks",
             `List
               (List.map
                  (fun c ->
                    `Assoc
                      [
                        ("index", `Int c.index);
                        ("h1", `String c.h1);
                        ("h2", `String c.h2);
                        ("size", `Int c.size);
                      ])
                  m.chunks) );
         ]
        @ match m.symlink with None -> [] | Some t -> [("symlink", `String t)])

let to_string state = Yojson.Basic.to_string (to_json state)
