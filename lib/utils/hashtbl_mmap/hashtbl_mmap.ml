(* Open addressing over two mappings: a blob of appended records, and a slot
   array of offsets into it.

   Records are never moved, so an offset stays good across a growth of either
   side, and growing the blob is an ftruncate and a fresh mapping of the same
   descriptor.

   Layout of a record, little-endian:
   {v
     0  4  key length
     4  4  value length
     8     key bytes, then value bytes
   v} *)

module type Storable = sig
  type t

  val to_string : t -> string
  val of_string : string -> t
end

module type S = sig
  type key
  type value
  type t

  val create : int -> t
  val replace : t -> key -> value -> unit
  val find : t -> key -> value
  val find_opt : t -> key -> value option
  val mem : t -> key -> bool
  val length : t -> int
  val iter : (key -> value -> unit) -> t -> unit
  val fold : (key -> value -> 'a -> 'a) -> t -> 'a -> 'a
end

type blob =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type slots = (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

let header_bytes = 8

(* A slot holds an offset biased by one, so zero can mean empty on a mapping
   that starts out zeroed. *)
let empty_slot = 0L

module Make (K : Storable) (V : Storable) = struct
  type key = K.t
  type value = V.t

  type t = {
    fd : Unix.file_descr;
    mutable blob : blob;
    mutable used : int;
    mutable slots : slots;
    mutable count : int;
  }

  let map_blob fd bytes =
    Unix.ftruncate fd bytes;
    Bigarray.array1_of_genarray
      (Unix.map_file fd Bigarray.char Bigarray.c_layout true [| bytes |])

  let rec pow2_at_least n acc =
    if acc >= n then acc else pow2_at_least n (acc * 2)

  let fresh_slots n =
    let s = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
    Bigarray.Array1.fill s empty_slot;
    s

  (* Unlinked while the descriptor is still open, so the inode lives exactly as
     long as this table and no name for it ever exists for anything else to
     find. *)
  let create n =
    let path = Filename.temp_file "hashtbl_mmap" "" in
    let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
    Unix.unlink path;
    let t =
      {
        fd;
        blob = map_blob fd (max 4096 (n * 64));
        used = 0;
        slots = fresh_slots (pow2_at_least (max 1 (2 * n)) 16);
        count = 0;
      }
    in
    Gc.finalise (fun t -> try Unix.close t.fd with Unix.Unix_error _ -> ()) t;
    t

  let put_int32 b off v =
    for i = 0 to 3 do
      Bigarray.Array1.unsafe_set b (off + i)
        (Char.unsafe_chr ((v lsr (i * 8)) land 0xff))
    done

  let int32_at b off =
    Char.code (Bigarray.Array1.unsafe_get b off)
    lor (Char.code (Bigarray.Array1.unsafe_get b (off + 1)) lsl 8)
    lor (Char.code (Bigarray.Array1.unsafe_get b (off + 2)) lsl 16)
    lor (Char.code (Bigarray.Array1.unsafe_get b (off + 3)) lsl 24)

  let put_string b off s =
    String.iteri (fun i c -> Bigarray.Array1.unsafe_set b (off + i) c) s

  let string_at b off len =
    String.init len (fun i -> Bigarray.Array1.unsafe_get b (off + i))

  let key_at t off = string_at t.blob (off + header_bytes) (int32_at t.blob off)

  let value_at t off =
    let klen = int32_at t.blob off in
    string_at t.blob (off + header_bytes + klen) (int32_at t.blob (off + 4))

  let ensure_room t need =
    let cap = Bigarray.Array1.dim t.blob in
    if need > cap then (
      let rec grow c = if c >= need then c else grow (c * 2) in
      t.blob <- map_blob t.fd (grow cap))

  let append t ks vs =
    let klen = String.length ks and vlen = String.length vs in
    ensure_room t (t.used + header_bytes + klen + vlen);
    let off = t.used in
    put_int32 t.blob off klen;
    put_int32 t.blob (off + 4) vlen;
    put_string t.blob (off + header_bytes) ks;
    put_string t.blob (off + header_bytes + klen) vs;
    t.used <- off + header_bytes + klen + vlen;
    off

  (* The slot [ks] belongs in: the one already holding it, else the first empty
     one along the probe. Growth keeps a quarter of the slots empty, so this
     always terminates. *)
  let slot_for slots blob ks =
    let mask = Bigarray.Array1.dim slots - 1 in
    let rec probe i =
      let s = Bigarray.Array1.unsafe_get slots i in
      if s = empty_slot then i
      else (
        let off = Int64.to_int s - 1 in
        if string_at blob (off + header_bytes) (int32_at blob off) = ks then i
        else probe ((i + 1) land mask))
    in
    probe (Hashtbl.hash ks land mask)

  (* Rehashed from the slots rather than by walking the blob: a key bound twice
     has a superseded record still sitting there, and reading the blob would
     bring it back. *)
  let grow_slots t =
    let old = t.slots in
    t.slots <- fresh_slots (Bigarray.Array1.dim old * 2);
    for i = 0 to Bigarray.Array1.dim old - 1 do
      let s = Bigarray.Array1.unsafe_get old i in
      if s <> empty_slot then (
        let ks = key_at t (Int64.to_int s - 1) in
        Bigarray.Array1.unsafe_set t.slots (slot_for t.slots t.blob ks) s)
    done

  let replace t k v =
    let ks = K.to_string k in
    let i = slot_for t.slots t.blob ks in
    let fresh = Bigarray.Array1.unsafe_get t.slots i = empty_slot in
    let off = append t ks (V.to_string v) in
    Bigarray.Array1.unsafe_set t.slots i (Int64.of_int (off + 1));
    if fresh then (
      t.count <- t.count + 1;
      if 4 * t.count > 3 * Bigarray.Array1.dim t.slots then grow_slots t)

  let find_opt t k =
    let s =
      Bigarray.Array1.unsafe_get t.slots
        (slot_for t.slots t.blob (K.to_string k))
    in
    if s = empty_slot then None
    else Some (V.of_string (value_at t (Int64.to_int s - 1)))

  let find t k = match find_opt t k with Some v -> v | None -> raise Not_found
  let mem t k = find_opt t k <> None
  let length t = t.count

  let fold f t acc =
    let acc = ref acc in
    for i = 0 to Bigarray.Array1.dim t.slots - 1 do
      let s = Bigarray.Array1.unsafe_get t.slots i in
      if s <> empty_slot then (
        let off = Int64.to_int s - 1 in
        acc :=
          f (K.of_string (key_at t off)) (V.of_string (value_at t off)) !acc)
    done;
    !acc

  let iter f t = fold (fun k v () -> f k v) t ()
end

module String = struct
  type t = string

  let to_string s = s
  let of_string s = s
end

module Int = struct
  type t = int

  let to_string n =
    let b = Bytes.create 8 in
    Bytes.set_int64_le b 0 (Int64.of_int n);
    Bytes.unsafe_to_string b

  (* [String] here is the one above, so the decoder names the stdlib's. *)
  let of_string s = Int64.to_int (Stdlib.String.get_int64_le s 0)
end
