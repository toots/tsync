(* What a partly filled cache-chunk body holds, and keeping that record straight
   while several reads fill one body at once. *)

type held = (int * (int * int)) list

let nothing = []
let interval t i = List.assoc_opt i t
let put t i span = (i, span) :: List.remove_assoc i t
let beside body = body ^ Cache_layout.manifest_suffix
let is_record name = Filename.check_suffix name Cache_layout.manifest_suffix

let render t =
  String.concat ""
    (List.map
       (fun (i, (a, b)) -> Printf.sprintf "%d %d %d\n" i a b)
       (List.sort compare t))

(* Strict: anything unreadable is taken as an empty body rather than as the part
   of one it can still be parsed as. A record is rewritten whole, so a
   half-written one means a write was interrupted, and the safe reading of that
   is that nothing landed. *)
let parse text =
  let line l =
    match String.split_on_char ' ' (String.trim l) with
      | [i; a; b] -> (
          match
            (int_of_string_opt i, int_of_string_opt a, int_of_string_opt b)
          with
            | Some i, Some a, Some b when i >= 0 && 0 <= a && a < b ->
                Some (i, (a, b))
            | _ -> None)
      | _ -> None
  in
  let rec go acc = function
    | [] -> List.rev acc
    | "" :: rest -> go acc rest
    | l :: rest -> (
        match line l with Some e -> go (e :: acc) rest | None -> [])
  in
  go [] (String.split_on_char '\n' text)

let widen ~have ~want =
  let c, d = want in
  match have with None -> want | Some (a, b) -> (min a c, max b d)

let missing ~have ~want =
  let c, d = want in
  match have with
    | None -> Some want
    | Some (a, b) ->
        if c >= a && d <= b then None
        else if d <= a then Some (c, a)
        else if c >= b then Some (b, d)
        else if c < a && d > b then Some (c, d)
        else if c < a then Some (c, a)
        else Some (b, d)

module Make
    (Io : Io.S)
    (Fs : Fs.S with type 'a io := 'a Io.t)
    (Sys : Syscalls.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* Held in memory as well as beside the body. A fill is a read, a fetch and a
     write, so two fills of one body would each save what it read before the
     other landed, dropping an interval whose bytes are on the disk -- and a
     body then never completes. The in-memory update runs without an intervening
     wait, which is what makes it atomic. *)
  let now : (string, held) Hashtbl.t = Hashtbl.create 16
  let recorded ~body = Sys.file_exists (beside body)

  let load ~key ~body =
    match Hashtbl.find_opt now key with
      | Some held -> Io.return held
      | None ->
          let+ text = Fs.read_file_opt (beside body) in
          let held = match text with None -> nothing | Some t -> parse t in
          Hashtbl.replace now key held;
          held

  (* One writer at a time per body: an [atomic_write] is a write and a rename
     with a wait between them, so two fills finishing together otherwise leave
     the earlier one's view on disk -- over a body that is by then whole, which
     reads as partial until something touches the chunk that view forgot.

     Its turn is kept beside what it writes and dropped with it, so nothing here
     outlives the record it is about. *)
  let publishing : (string, unit Io.t) Hashtbl.t = Hashtbl.create 16

  let reset ~key =
    Hashtbl.remove now key;
    Hashtbl.remove publishing key

  let drop ~key ~body =
    reset ~key;
    Fs.unlink_quiet (beside body)

  let drop_beside ~body = Fs.unlink_quiet (beside body)

  (* Before the first byte it will describe, so what a crash leaves is a body
     claiming less than it holds rather than one with nothing to say it is
     incomplete. Writes the empty record rather than what is held, and touches
     nothing in memory: two reads can both find no body and both start it, and
     the one that gets here second must not take back what the first recorded. *)
  let start ~body = Fs.atomic_write (beside body) (render nothing)

  let take ~key i span =
    let held = Option.value (Hashtbl.find_opt now key) ~default:nothing in
    let span = widen ~have:(interval held i) ~want:span in
    Hashtbl.replace now key (put held i span)

  (* Each reads what is recorded when its turn comes rather than what its own
     fill saw, so the last one out is the one that decides. *)
  let publish ~key ~body ~complete =
    let write () =
      match Hashtbl.find_opt now key with
        | None -> return_unit
        | Some held when complete held -> drop ~key ~body
        | Some held -> Fs.atomic_write (beside body) (render held)
    in
    let prev =
      Option.value (Hashtbl.find_opt publishing key) ~default:return_unit
    in
    let t = Io.bind prev write in
    Hashtbl.replace publishing key t;
    t
end
