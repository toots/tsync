open Tsync_core

(* The uuid is created race-free across processes: a durable temporary linked
   to its final name, the loser reading the winner's. *)
let client_uuid data_dir =
  let p = Filename.concat data_dir "client-uuid" in
  let read () =
    match Fs.read_file_opt p with
      | Some s -> (
          match String.split_on_char '\n' s with
            | l :: _ when String.trim l <> "" -> Some (String.trim l)
            | _ -> None)
      | None -> None
  in
  match read () with
    | Some u -> u
    | None -> (
        Fs.mkdir_p data_dir;
        ignore (Fs.create_if_absent p (Ids.token () ^ "\n"));
        match read () with Some u -> u | None -> Fail.corrupt "%s is empty" p)

let block_size = 1024

type minter = {
  dir : string;
  uuid : string;
  m : Mutex.t;
  mutable pid : int;
  mutable block : int;
  mutable next : int;
}

let minter ~data_dir ~uuid =
  {
    dir = Filename.concat data_dir "id-leases";
    uuid;
    m = Mutex.create ();
    pid = -1;
    block = 0;
    next = block_size;
  }

let highest_block dir =
  List.fold_left
    (fun acc n ->
      match int_of_string_opt ("0x" ^ n) with
        | Some b when b > acc -> b
        | _ -> acc)
    (-1) (Fs.readdir dir)

(* A block is leased by creating its file durably before its first id is
   used; a forked child leases its own. *)
let lease t =
  Fs.mkdir_p t.dir;
  let rec go b =
    match
      Fs.create_if_absent (Filename.concat t.dir (Printf.sprintf "%x" b)) ""
    with
      | `Created -> b
      | `Exists -> go (b + 1)
  in
  t.block <- go (highest_block t.dir + 1);
  t.next <- 0;
  t.pid <- Unix.getpid ()

let mint t =
  Mutex.protect t.m (fun () ->
      if t.pid <> Unix.getpid () || t.next >= block_size then lease t;
      let counter = (t.block * block_size) + t.next in
      t.next <- t.next + 1;
      Folder_id.mint ~uuid:t.uuid ~counter)
