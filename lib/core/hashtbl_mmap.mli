(** A hash table whose entries live in a mapping rather than on the OCaml heap.

    For a table whose size the data chooses — the keys a store holds, the
    objects a listing names — holding bytes the program never computes with and
    only looks up. On the heap those are scanned and copied by a collector with
    nothing to gain from either; here they are pages the kernel can reclaim, and
    the backing file is unlinked the instant it is mapped, so a process that
    dies leaves nothing to clean up. *)
module type Storable = Hashtbl_mmap_intf.Storable

(** The subset of {!Stdlib.Hashtbl.S} a mapping can honour, with the same names
    and the same meanings.

    Values are bytes rather than arbitrary OCaml values, so ['a t] is [t] and
    the value type joins the key as an argument to {!Make}; that substitution
    aside, everything here behaves as its counterpart does. Absent are [add],
    [remove], [clear], [copy], [find_all] and [filter_map_inplace] — open
    addressing would need tombstones and a second growth rule to offer the
    removals, and [add] without them differs from {!S.replace} only in ways
    nothing left could observe. *)
module type S = Hashtbl_mmap_intf.S

(** Keys are hashed with {!Stdlib.Hashtbl.hash} over [K.to_string], so a table
    here distributes as the stdlib one it stands in for. *)
module Make (K : Storable) (V : Storable) :
  S with type key = K.t and type value = V.t

module String : Storable with type t = string

(** Eight bytes, so a binding occupies the same room whatever it holds. *)
module Int : Storable with type t = int
