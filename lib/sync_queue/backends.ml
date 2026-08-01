(* The shape of the configured backend list: the head is the primary and serves
   every read, and a write goes to all of them, in order. Nothing here is more
   than a line; the point is that both questions are answered once. *)

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with
      | b :: _ -> b
      | [] -> failwith "no backends configured"

  (* Sequential on purpose: a write must land on the primary before any replica,
     so a crash part-way leaves replicas behind rather than ahead. *)
  let all f = Lwt_list.iter_s f C.backends
  let put ~key ~data = all (fun (module B : Backend.S) -> B.put ~key ~data ())
  let delete ~key = all (fun (module B : Backend.S) -> B.delete ~key ())

  let delete_many keys =
    if keys = [] then Lwt.return_unit
    else all (fun (module B : Backend.S) -> B.delete_multi keys)

  let copy ~src_key ~dst_key =
    all (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
end
