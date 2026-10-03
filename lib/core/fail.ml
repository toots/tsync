(* Failure kinds of spec failure-model §3: the kind is decided once, by the
   layer with the evidence, and travels as data. *)

type kind =
  | Absent
  | Exists
  | Not_empty
  | Denied
  | Read_only
  | Refused
  | Invalid
  | Corrupt
  | Missing_chunks of string list
  | Paused
  | Unprepared
  | Link
  | Load
  | Local
  | Unreachable
  | Deadline
  | Unexplained

type t = {
  kind : kind;
  op : string;
  reason : string;
  repair : string option;
  retry_after : float option;
}

exception E of t

let make ?repair ?retry_after ?(op = "") kind reason =
  { kind; op; reason; repair; retry_after }

let raise_ ?repair ?retry_after ?op kind fmt =
  Printf.ksprintf
    (fun reason -> raise (E (make ?repair ?retry_after ?op kind reason)))
    fmt

let kind_name = function
  | Absent -> "absent"
  | Exists -> "exists/exists"
  | Not_empty -> "exists/not_empty"
  | Denied -> "refused/denied"
  | Read_only -> "refused/read_only"
  | Refused -> "refused/other"
  | Invalid -> "invalid"
  | Corrupt -> "corrupt/other"
  | Missing_chunks _ -> "corrupt/missing_chunks"
  | Paused -> "unprepared/paused"
  | Unprepared -> "unprepared/other"
  | Link -> "transient/link"
  | Load -> "transient/load"
  | Local -> "transient/local"
  | Unreachable -> "unreachable"
  | Deadline -> "deadline"
  | Unexplained -> "unexplained"

let retryable = function
  | Link | Load | Local | Unreachable | Deadline -> true
  | _ -> false

let to_string f =
  let base = if f.op = "" then f.reason else f.op ^ ": " ^ f.reason in
  match f.repair with Some r -> base ^ " (" ^ r ^ ")" | None -> base

let () =
  Printexc.register_printer (function
    | E f -> Some (Printf.sprintf "%s [%s]" (to_string f) (kind_name f.kind))
    | _ -> None)

external errno_numbers : unit -> int * int * int * int * int
  = "tsync_errno_numbers"

let estale, edquot, etxtbsy, enolink, eremoteio = errno_numbers ()

(* failure-model §4.1: one table for every local filesystem access. *)
let kind_of_errno = function
  | Unix.ENOENT | Unix.ENOTDIR -> Absent
  | Unix.EEXIST -> Exists
  | Unix.ENOTEMPTY -> Not_empty
  | Unix.ETIMEDOUT | Unix.EHOSTDOWN | Unix.EHOSTUNREACH | Unix.ENETDOWN
  | Unix.ENETUNREACH | Unix.ECONNRESET | Unix.ECONNREFUSED | Unix.ECONNABORTED
  | Unix.ENOTCONN ->
      Link
  | Unix.EMFILE | Unix.ENFILE | Unix.ENOMEM | Unix.ENOBUFS | Unix.ENOSPC
  | Unix.EIO | Unix.EAGAIN | Unix.EBUSY ->
      Local
  | Unix.EACCES | Unix.EPERM -> Denied
  | Unix.EROFS -> Read_only
  | Unix.EUNKNOWNERR n when n = estale || n = enolink || n = eremoteio -> Link
  | Unix.EUNKNOWNERR n when n = edquot || n = etxtbsy -> Local
  | _ -> Refused

let of_unix ?(op = "") err fn arg =
  let what = if arg = "" then fn else fn ^ " " ^ arg in
  make ~op (kind_of_errno err)
    (Printf.sprintf "%s: %s" what (Unix.error_message err))

(* Anything nobody classified is UNEXPLAINED, except the runtime's own
   answers which keep their meaning. *)
let classify ?(op = "") = function
  | E f -> f
  | Unix.Unix_error (e, fn, arg) -> of_unix ~op e fn arg
  | Rt.Timeout -> make ~op Link "stalled"
  | Out_of_memory -> make ~op Local "out of memory"
  | exn -> make ~op Unexplained (Printexc.to_string exn)

(* failure-model §7.2: the only mapping from kinds to client codes. *)
let code = function
  | Absent -> "not_found"
  | Exists -> "exists"
  | Not_empty -> "not_empty"
  | Read_only -> "read_only"
  | Denied -> "denied"
  | Invalid -> "invalid"
  | Unreachable -> "unreachable"
  | Load -> "busy"
  | Paused -> "paused"
  | _ -> "internal"

let kind_of_code = function
  | "not_found" -> Absent
  | "exists" -> Exists
  | "not_empty" -> Not_empty
  | "read_only" -> Read_only
  | "denied" -> Denied
  | "invalid" -> Invalid
  | "unreachable" -> Unreachable
  | "busy" -> Load
  | "paused" -> Paused
  | _ -> Unexplained

(* The x-tsync-kind vocabulary of the peer wire. *)
let wire_kind = function
  | Absent -> Some "absent"
  | Exists -> Some "exists"
  | Not_empty -> Some "not_empty"
  | Denied -> Some "denied"
  | Read_only -> Some "read_only"
  | Refused -> Some "other"
  | Invalid -> Some "invalid"
  | Corrupt -> Some "corrupt"
  | Missing_chunks _ -> Some "missing_chunks"
  | Paused | Unprepared -> Some "unprepared"
  | _ -> None

let of_wire_kind = function
  | "absent" -> Absent
  | "exists" -> Exists
  | "not_empty" -> Not_empty
  | "denied" -> Denied
  | "read_only" -> Read_only
  | "invalid" -> Invalid
  | "corrupt" -> Corrupt
  | "unprepared" -> Unprepared
  | "missing_chunks" -> Missing_chunks []
  | _ -> Refused

let errno = function
  | Absent -> Unix.ENOENT
  | Exists -> Unix.EEXIST
  | Not_empty -> Unix.ENOTEMPTY
  | Denied -> Unix.EACCES
  | Read_only -> Unix.EROFS
  | Invalid -> Unix.EINVAL
  | _ -> Unix.EIO

let absent ?op fmt = raise_ ?op Absent fmt
let invalid ?op fmt = raise_ ?op Invalid fmt
let corrupt ?op fmt = raise_ ?op Corrupt fmt
let is_absent = function E { kind = Absent; _ } -> true | _ -> false
