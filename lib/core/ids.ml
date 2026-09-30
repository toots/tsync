let urandom n =
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic n)

let hex s =
  String.concat ""
    (List.map
       (fun c -> Printf.sprintf "%02x" (Char.code c))
       (List.of_seq (String.to_seq s)))

let token () = hex (urandom 16)
let secret () = hex (urandom 32)

(* The generator is tagged with the pid that seeded it, so a forked child
   reseeds before its first draw. *)
let m = Mutex.create ()
let state = ref None

let short () =
  Mutex.protect m (fun () ->
      let pid = Unix.getpid () in
      let st =
        match !state with
          | Some (p, st) when p = pid -> st
          | _ ->
              let seed = urandom 16 in
              let st =
                Random.State.make
                  (Array.init 4 (fun i ->
                       Int32.to_int (String.get_int32_le seed (i * 4))))
              in
              state := Some (pid, st);
              st
      in
      Printf.sprintf "%016Lx" (Random.State.bits64 st))
