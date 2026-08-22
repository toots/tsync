open Lwt.Syntax

type 'a t = {
  spool : Spool.t;
  decode : Bigstring.t -> int ref -> 'a;
  mutable count : int;
  mutable body : Bigstring.t option;
}

let create ~dir ~name ~decode =
  let+ spool = Spool.create ~dir ~name in
  { spool; decode; count = 0; body = None }

let str b s =
  Buffer.add_int32_le b (Int32.of_int (String.length s));
  Buffer.add_string b s

let int64 b n = Buffer.add_int64_le b n

let add t fields =
  if t.body <> None then
    invalid_arg "Listing.add: the spool has been sealed to be read";
  let b = Buffer.create 128 in
  List.iter (fun f -> f b) fields;
  t.count <- t.count + 1;
  Spool.append t.spool (Buffer.contents b)

let take body pos n =
  let s = Bigstring.substring body ~off:!pos ~len:n in
  pos := !pos + n;
  s

let read_int body pos = Int32.to_int (String.get_int32_le (take body pos 4) 0)
let read_int64 body pos = String.get_int64_le (take body pos 8) 0

let read_string body pos =
  let n = read_int body pos in
  take body pos n

let count t = t.count

(* Sealed once and mapped once, so a caller walking it for each of several
   destinations reads the same pages every time. *)
let body t =
  match t.body with
    | Some body -> Lwt.return body
    | None ->
        let+ body = Spool.seal t.spool in
        t.body <- Some body;
        body

type 'a cursor = {
  body : Bigstring.t;
  pos : int ref;
  read : Bigstring.t -> int ref -> 'a;
}

let read t =
  let+ body = body t in
  { body; pos = ref 0; read = t.decode }

let next c =
  if !(c.pos) >= Bigstring.length c.body then None else Some (c.read c.body c.pos)

let iter t f =
  let* c = read t in
  let rec go () =
    match next c with None -> Lwt.return_unit | Some r -> Lwt.bind (f r) go
  in
  go ()

let drop t = Spool.drop t.spool
let reap ~dir = Spool.reap ~dir
