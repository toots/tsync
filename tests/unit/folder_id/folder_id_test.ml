(* A folder id is unique without asking anyone: other clients are kept apart by
   the uuid, and this client's own processes by the counter blocks they lease.
   The processes here run at once and see nothing of each other but the data
   directory, as the daemon's forked frontends do. *)

open Check

let root = Scratch.dir "folder_id"

module C =
  (val Fixture.conf ~root:(Filename.concat root "minting") () : Conf_lwt.S)

module Fresh_conf =
  (val Fixture.conf ~root:(Filename.concat root "fresh") () : Conf_lwt.S)

module J = Journal.Make (C)

(* Starts [n] children held at a barrier, releases them together, and answers
   the lines each wrote. *)
let at_once n work =
  let barrier_r, barrier_w = Unix.pipe () in
  let children =
    List.init n (fun _ ->
        let r, w = Unix.pipe () in
        match Unix.fork () with
          | 0 ->
              Unix.close r;
              Unix.close barrier_w;
              (try ignore (Unix.read barrier_r (Bytes.create 1) 0 1)
               with _ -> ());
              let oc = Unix.out_channel_of_descr w in
              List.iter (fun line -> output_string oc (line ^ "\n")) (work ());
              close_out oc;
              Unix._exit 0
          | pid ->
              Unix.close w;
              (pid, r))
  in
  Unix.close barrier_w;
  let lines =
    List.map
      (fun (pid, r) ->
        let ic = Unix.in_channel_of_descr r in
        let rec read acc =
          match input_line ic with
            | line -> read (line :: acc)
            | exception End_of_file -> List.rev acc
        in
        let lines = read [] in
        close_in ic;
        ignore (Unix.waitpid [] pid);
        lines)
      children
  in
  Unix.close barrier_r;
  lines

let counter id =
  match String.index_opt id '-' with
    | Some i ->
        int_of_string ("0x" ^ String.sub id (i + 1) (String.length id - i - 1))
    | None -> -1

let is_hex s =
  s <> ""
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let () =
  case "one id";
  let id = J.folder_id () in
  let prefix = String.sub (J.client_uuid ()) 0 12 in
  check "names the client by the first 12 hex of its uuid"
    ~why:(fun () -> id)
    (String.length id > 13 && String.sub id 0 13 = prefix ^ "-");
  check "and a counter in hex after it"
    (is_hex (String.sub id 13 (String.length id - 13)));

  case "processes minting at once";
  (* More than two blocks each, so every process leases past its first. *)
  let per_process = (2 * 1024) + 10 in
  let children =
    at_once 3 (fun () -> List.init per_process (fun _ -> J.folder_id ()))
  in
  let parent = List.init per_process (fun _ -> J.folder_id ()) in
  let all = parent @ List.concat children in
  step "%d ids from %d processes" (List.length all) (List.length children + 1);
  check "each process minted what it was asked"
    (List.for_all
       (fun ids -> List.length ids = per_process)
       (parent :: children));
  check "and no two ids are the same"
    (List.length (List.sort_uniq compare all) = List.length all);

  case "a process started later";
  let highest = List.fold_left (fun acc id -> max acc (counter id)) (-1) all in
  let later = List.concat (at_once 1 (fun () -> [J.folder_id ()])) in
  check "counts on from above everything minted before"
    (later <> [] && List.for_all (fun id -> counter id > highest) later);

  case "processes naming a new client at once";
  let module Fresh = Journal.Make (Fresh_conf) in
  let uuids = List.concat (at_once 12 (fun () -> [Fresh.client_uuid ()])) in
  check "all read one uuid"
    ~why:(fun () -> String.concat ", " uuids)
    (List.length uuids = 12
    && List.for_all (fun u -> u = List.hd uuids && String.length u = 32) uuids);
  report ~expected:6 ();
  Scratch.cleanup root
