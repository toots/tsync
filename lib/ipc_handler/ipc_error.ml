(* What went wrong, as something a caller can act on.

   Frontends translate a failure into their own vocabulary, and the macOS one must
   pick carefully: some of its error codes make the system back off until
   signalled, others make it retry, and getting that backwards turns a daemon
   restart into a domain that stays broken. Matching on the wording of an
   exception breaks the day the wording changes, so the wire carries a code and
   the prose is only for a human. *)

type t =
  [ `Not_found
  | `Exists
  | `Not_empty
  | `Read_only
  | `Unreachable
  | `Denied
  | `Invalid
  | `Internal ]

let to_string = function
  | `Not_found -> "not_found"
  | `Exists -> "exists"
  | `Not_empty -> "not_empty"
  | `Read_only -> "read_only"
  | `Unreachable -> "unreachable"
  | `Denied -> "denied"
  | `Invalid -> "invalid"
  | `Internal -> "internal"

(* [Unreachable] tells a caller the store is the problem and to stop trying, so
   anything unplaceable is [Internal] and retried: one unexplained failure should
   cost one operation, not the domain. *)
let of_exn = function
  | Unix.Unix_error (Unix.ENOENT, _, _) -> `Not_found
  | Unix.Unix_error (Unix.EEXIST, _, _) -> `Exists
  | Unix.Unix_error (Unix.ENOTEMPTY, _, _) -> `Not_empty
  | Unix.Unix_error ((Unix.EPERM | Unix.EACCES), _, _) -> `Denied
  | Unix.Unix_error (Unix.EROFS, _, _) -> `Read_only
  | Backend.Not_writable -> `Read_only
  | Backend.Backend_error _ | Lwt_unix.Timeout -> `Unreachable
  | Share.Share_not_found _ -> `Not_found
  | Share.Share_unavailable _ -> `Unreachable
  | Invalid_argument _ -> `Invalid
  | Failure msg when String.starts_with ~prefix:"no versions for" msg ->
      `Not_found
  | _ -> `Internal
