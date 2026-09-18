(* What an export in flight looks like, as a function of what is known about it:
   no clock and no terminal in here, so a snapshot can hold every line. *)

type active = { name : string; moved : int64; total : int64; rate : float }

type state = {
  files : int;
  finished : int;
  moved : int64;
  total : int64;
  rate : float;
  active : active list;
}

let phrase ~moved ~total ~rate =
  Menu.progress_text
    {
      Menu.name = "";
      rel = "";
      moved = Some moved;
      total = Some total;
      rate = Some rate;
    }

let active_line (a : active) =
  String.concat " · "
    (Filename.basename a.name
    :: Option.to_list (phrase ~moved:a.moved ~total:a.total ~rate:a.rate))

let total_line s =
  String.concat " · "
    (Printf.sprintf "%d of %d file%s" s.finished s.files
       (if s.files = 1 then "" else "s")
    :: Option.to_list (phrase ~moved:s.moved ~total:s.total ~rate:s.rate))

(* One file is its own total, and saying it twice is a line too many. *)
let render s =
  let active =
    List.sort (fun (a : active) b -> compare a.name b.name) s.active
  in
  match (s.files, active) with
    | 0, _ -> []
    | 1, [a] -> [active_line a]
    | _ -> List.map active_line active @ [total_line s]
