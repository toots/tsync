type 'a t = (string, 'a) Hashtbl.t

let create () = Hashtbl.create 4
let register = Hashtbl.replace
let find = Hashtbl.find_opt
let names t = List.sort compare (List.of_seq (Hashtbl.to_seq_keys t))
