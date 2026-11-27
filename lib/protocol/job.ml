type copies = Probe | Outstanding | Retry_outstanding [@@deriving yojson]

(** Which versions expire (gc.md §4.1): by age, or the expiry list at an
    absolute path, which the owner reads. *)
type expiry = [ `Before of float | `Listed of string ] [@@deriving yojson]

type t =
  | Sync of { full : bool }
  | Gc of {
      apply : bool;
      verify : bool;
      abort : bool;
      budget : float option;
      expire : expiry option;
    }
  | Gc_copies of copies
  | Expire of {
      apply : bool;
      expiry : expiry;
      export : string option;  (** absolute: the owner writes it *)
    }
  | Void_entry of { n : int }
  | Import of {
      src : string;
      only : string list;
      exclude : string list;
      force_rehash : bool;
      map : string option; [@default None]
    }
  | Rsync of {
      src : string;
      src_in_domain : bool;
      dst : string;
      dst_in_domain : bool;
      move : bool;
      dry_run : bool;
    }
  | Mirror of {
      source : string option;
      skip_chunks : bool;
      path : string option;
    }
  | Integrity of {
      verify : bool;
      repair : bool;
      apply : bool;
      detail : bool;
      source : string option;
    }
[@@deriving yojson]

let kind = function
  | Sync { full = true } -> "sync --full"
  | Sync _ -> "sync"
  | Gc { abort = true; _ } -> "gc --abort"
  | Gc { apply = true; _ } -> "gc --apply"
  | Gc _ -> "gc"
  | Gc_copies Probe -> "gc --probe"
  | Gc_copies Outstanding -> "gc --outstanding"
  | Gc_copies Retry_outstanding -> "gc --retry-outstanding"
  | Expire { expiry = `Listed _; _ } -> "expire --from"
  | Expire { export = Some _; _ } -> "expire --export"
  | Expire _ -> "expire"
  | Void_entry _ -> "void-entry"
  | Import _ -> "import"
  | Mirror _ -> "mirror"
  | Rsync { move = true; _ } -> "rsync --move"
  | Rsync _ -> "rsync"
  | Integrity { verify = true; _ } -> "data-integrity --verify"
  | Integrity { repair = true; _ } -> "data-integrity --repair"
  | Integrity _ -> "data-integrity"
