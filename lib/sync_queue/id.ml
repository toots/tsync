(* Random hex ids: staged-body names, folder ids, share tokens, the client uuid.

   Two generators. Body and folder ids are minted on the write path, one per
   staged chunk, and only need not to collide, so they come from a PRNG seeded
   once. Share tokens and the client uuid are minted rarely, and a share token is
   the only thing guarding a public URL, so those come from the kernel.

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

(* Tests fix the seed so folder ids — and with them backend key ordering and
   every snapshot — are reproducible. *)
let reseed n = state := Random.State.make [| n |]

(* 64 bits: enough that the staged bodies alive at any moment never collide. *)
let short () =
  Printf.sprintf "%08Lx%08Lx"
    (Random.State.int64 !state 0x1_0000_0000L)
    (Random.State.int64 !state 0x1_0000_0000L)
