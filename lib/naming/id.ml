(* Two generators: a PRNG seeded once for ids minted on the write path, which
   only need not to collide, and the kernel for the rare ids whose
   unguessability is load-bearing.

   The PRNG carries its own state rather than using the global [Random], which is
   only as seeded as whichever module called [Random.self_init] first — a
   link-order dependency that could silently hand every process the same ids. *)

let hex_of_bytes b =
  String.concat ""
    (List.init (Bytes.length b) (fun i ->
         Printf.sprintf "%02x" (Char.code (Bytes.get b i))))

(* Raises if /dev/urandom cannot be read: a caller asking for this wants
   unguessability and must not get a fallback. *)
let token n =
  let b = Bytes.create n in
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input ic b 0 n);
  hex_of_bytes b

let seed_from_kernel () =
  match token 8 with
    | h -> Array.init 4 (fun i -> int_of_string ("0x" ^ String.sub h (i * 4) 4))
    | exception _ ->
        [| Unix.getpid (); int_of_float (Unix.gettimeofday () *. 1e6) |]

let state = ref (Random.State.make (seed_from_kernel ()))

(* 64 bits: enough that the staged bodies alive at any moment never collide. *)
let short () =
  Printf.sprintf "%08Lx%08Lx"
    (Random.State.int64 !state 0x1_0000_0000L)
    (Random.State.int64 !state 0x1_0000_0000L)
