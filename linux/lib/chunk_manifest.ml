let content_type = "application/x-tsync-manifest+json"
let chunk_size = 8 * 1024 * 1024

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }
type t = { v : int; size : int64; chunk_size : int; chunks : chunk_entry list }

let chunk_key entry = entry.h1 ^ "-" ^ entry.h2

let of_json json =
  let open Yojson.Basic.Util in
  {
    v = json |> member "v" |> to_int;
    size = json |> member "size" |> to_int |> Int64.of_int;
    chunk_size = json |> member "chunkSize" |> to_int;
    chunks =
      json |> member "chunks" |> to_list
      |> List.map (fun c ->
          {
            index = c |> member "index" |> to_int;
            h1 = c |> member "h1" |> to_string;
            h2 = c |> member "h2" |> to_string;
            size = c |> member "size" |> to_int;
          });
  }

let of_string s = of_json (Yojson.Basic.from_string s)

let to_json manifest =
  `Assoc
    [
      ("v", `Int manifest.v);
      ("size", `Int (Int64.to_int manifest.size));
      ("chunkSize", `Int manifest.chunk_size);
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
             manifest.chunks) );
    ]

let to_string manifest = Yojson.Basic.to_string (to_json manifest)
