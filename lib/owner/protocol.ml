open Tsync_core
module R = Tsync_status.Status_report

type availability = Online_only | Cached | Pinned of float

(** A new item: a parent folder's reference and a leaf. *)
type destination = { parent_ref : string; name : string }

type target = Ref of string | Rel of string | Child of destination

type row = {
  ref_ : string;
  parent_ref : string;
  name : string;
  kind : [ `Dir | `File | `Symlink ];
  size : int;
  mtime : float;
  etag : string;
  is_uploaded : bool;
  content_id : string option;
  symlink_target : string option;
  read_only : bool;
  availability : availability option;
}

type page = {
  items : row list;
  next : string option;
  unnamed : int;
  pulled_at : float option;
      (** pulled tree: when the pull the rows reflect completed (android §3.2)
      *)
  outdated : bool;  (** pulled tree: the rows are not from a fresh pull *)
}

(** android §3.2 rule 1: pull unless fresh, pull even when fresh, or answer the
    mirror. *)
type pull = [ `Auto | `Now | `Never ]

(** A whole-domain page, or [Walk_stale] for a cursor on another walk. *)
type listing = Listed of page | Walk_stale

type written = { size : int; mtime : float; item : row }

type fetched = {
  local_path : string;
  offset : int;
  length : int;
  item : row;  (** the version whose bytes were written *)
}

type cached = { local_path : string; item : row }

(** A change-feed op as 08 §3.6 renders it: items named by reference. *)
type feed_op =
  | Put_op of {
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }
  | Delete_op of { ref_ : string; parent_ref : string; name : string }
  | Mkdir_op of {
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }
  | Rmdir_op of {
      id : string;
      ref_ : string;
      parent_ref : string;
      name : string;
    }
  | Rename_op of {
      is_dir : bool;
      id : string option;
      src_ref : string;
      src_parent_ref : string;
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }

type changes =
  | Stale
  | Changes of {
      cursor : string;
      more : bool;
      ops : feed_op list;
      unnamed : int;
    }

type counted = { succeeded : int; failed : int }
type progress = Inactive | Active of { downloaded : int; total : int }
type resynced = Incremental of int | Full of { manifests : int; failed : int }
type trash_restored = Restored of int | Not_in_trash | Name_taken
type shared = { url : string; expires : float }

(** A transfer as [status] lists it (08 §3.3). *)
type transfer = {
  name : string;
  rel : string;
  bytes : int;
  size : int;
  seconds : float;
  rate : float;
}
[@@deriving yojson { strict = false }]

type status = {
  domain : string;
  read_only : bool;
  paused : bool;
  pending_uploads : int;
  pending_downloads : int;
  uploading : transfer list;
  downloading : transfer list;
  pending_bytes : int;
  subscribers : int;
  unnamed : int;
  traffic : R.traffic;
  mount : string option;
}

type _ request =
  | Ping : unit request
  | Stat : target -> row request
  | List_dir : {
      dir : target;
      after : string option;
      limit : int option;
      pull : pull;
    }
      -> page request
  | List_all : { after : string option; limit : int option } -> listing request
  | Cursor : string request
  | Changes_since : { anchor : string; limit : int option } -> changes request
  | Ensure_cached : { item : target; dest : string } -> cached request
  | Fetch_range : {
      item : target;
      dest : string;
      offset : int;
      length : int;
    }
      -> fetched request
  | Download_progress : target -> progress request
  | Create : { at : destination; exclusive : bool } -> row request
  | Write : {
      at : target;  (** a file by [Ref], or a place by [Child] *)
      staging : string;
      base : string option;
      exclusive : bool;
      await : bool;  (** answer once the upload published or started failing *)
    }
      -> written request
  | Mkdir : { at : destination; exclusive : bool } -> row request
  | Symlink : {
      at : destination;
      link_target : string;
      exclusive : bool;
    }
      -> row request
  | Rename : { src : string; at : destination; noreplace : bool } -> row request
  | Delete : target -> unit request
  | Rmdir : target -> unit request
  | Evict : target -> counted request
  | Restore : { item : target; keep : float option } -> counted request
  | Revert : { item : target; version : int64 option } -> unit request
      (** [version]: a timestamp in ns; none is the newest *)
  | Full_resync : unit request
  | Sync : { full : bool } -> resynced request
  | Trash_restore : string -> trash_restored request
  | Share : {
      item : target;  (** the domain root when the request names nothing *)
      expires : float option;
      token : string option;
    }
      -> shared request
  | Share_revoke : string -> bool request
  | Share_preview : string -> [ `Made | `Not_made of string ] request
  | Share_clear_cache : (int * int) request
  | Job : { job : Jobs.t; narrate : bool } -> int request
  | Cancel : int -> bool request
  | Retry : int request
  | Poll : unit request
  | Notify_reset : int request
  | Status : status request
  | Pause : bool -> bool request
  | Stats : string list -> R.answer request
  | Stop : unit request

type packed = Request : 'a request -> packed

let action : type a. a request -> string = function
  | Ping -> "ping"
  | Stat _ -> "stat"
  | List_dir _ -> "list_dir"
  | List_all _ -> "list_all"
  | Cursor -> "cursor"
  | Changes_since _ -> "changes_since"
  | Ensure_cached _ -> "ensure_cached"
  | Fetch_range _ -> "fetch_range"
  | Download_progress _ -> "download_progress"
  | Create _ -> "create"
  | Write _ -> "write"
  | Mkdir _ -> "mkdir"
  | Symlink _ -> "symlink"
  | Rename _ -> "rename"
  | Delete _ -> "delete"
  | Rmdir _ -> "rmdir"
  | Evict _ -> "evict"
  | Restore _ -> "restore"
  | Revert _ -> "revert"
  | Full_resync -> "full_resync"
  | Sync _ -> "sync"
  | Trash_restore _ -> "trash_restore"
  | Share _ -> "share"
  | Share_revoke _ -> "share_revoke"
  | Share_preview _ -> "share_preview"
  | Share_clear_cache -> "share_clear_cache"
  | Job _ -> "job"
  | Cancel _ -> "cancel"
  | Retry -> "retry"
  | Poll -> "poll"
  | Notify_reset -> "notify_reset"
  | Status -> "status"
  | Pause _ -> "pause"
  | Stats _ -> "stats"
  | Stop -> "stop"

let mutates : type a. a request -> bool = function
  | Create _ | Write _ | Mkdir _ | Symlink _ | Rename _ | Delete _ | Rmdir _
  | Revert _ ->
      true
  | _ -> false

let bulk : type a. a request -> bool = function
  | Ensure_cached _ | Fetch_range _ | Write _ | Evict _ | Restore _ | Sync _
  | Trash_restore _ | Job _ ->
      true
  | List_all { after = None; _ } -> true
  | _ -> false

let refused_while_paused : type a. a request -> bool = function
  | Revert _ | Sync _ | Trash_restore _ | Job _ | Share _ | Share_revoke _
  | Share_preview _ | Share_clear_cache ->
      true
  | _ -> false

type event = Recovered | Reset | Changed

let event_name = function
  | Recovered -> "recovered"
  | Reset -> "reset"
  | Changed -> "changed"

(* Field access on the owner side: a wrong type is INVALID, never a crash. *)
let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let str j k =
  match member j k with
    | Some (`String s) -> Some s
    | None | Some `Null -> None
    | Some _ -> Fail.invalid "%s must be a string" k

let required j k =
  match str j k with Some s -> s | None -> Fail.invalid "%s is required" k

let flag j k =
  match member j k with
    | Some (`Bool b) -> b
    | None | Some `Null -> false
    | Some _ -> Fail.invalid "%s must be a boolean" k

let int j k =
  match member j k with
    | Some (`Int i) -> Some i
    | None | Some `Null -> None
    | Some _ -> Fail.invalid "%s must be an integer" k

let number j k =
  match member j k with
    | Some (`Int i) -> Some (float_of_int i)
    | Some (`Float f) -> Some f
    | None | Some `Null -> None
    | Some _ -> Fail.invalid "%s must be a number" k

let opt k f = function Some v -> [(k, f v)] | None -> []

let destination_fields (d : destination) =
  [("parentRef", `String d.parent_ref); ("name", `String d.name)]

let target_fields = function
  | Ref r -> [("ref", `String r)]
  | Rel p -> [("rel", `String p)]
  | Child d -> destination_fields d

let target_of j =
  match (str j "ref", str j "rel", str j "parentRef") with
    | Some r, _, _ -> Ref r
    | None, Some p, _ -> Rel p
    | None, None, Some parent_ref ->
        Child { parent_ref; name = required j "name" }
    | None, None, None -> Fail.invalid "ref, rel or parentRef is required"

let destination_of j =
  { parent_ref = required j "parentRef"; name = required j "name" }

let request_fields : type a. a request -> (string * Yojson.Safe.t) list =
  function
  | Ping | Cursor | Full_resync | Retry | Poll | Notify_reset | Status | Stop
  | Share_clear_cache ->
      []
  | Stat t | Download_progress t | Delete t | Rmdir t | Evict t ->
      target_fields t
  | List_all r ->
      opt "after" (fun a -> `String a) r.after
      @ opt "limit" (fun l -> `Int l) r.limit
  | Changes_since r ->
      ("arg", `String r.anchor) :: opt "limit" (fun l -> `Int l) r.limit
  | List_dir r -> (
      target_fields r.dir
      @ opt "after" (fun a -> `String a) r.after
      @ opt "limit" (fun l -> `Int l) r.limit
      @
        match r.pull with
        | `Auto -> []
        | `Now -> [("pull", `String "now")]
        | `Never -> [("pull", `String "never")])
  | Ensure_cached r -> target_fields r.item @ [("dest", `String r.dest)]
  | Fetch_range r ->
      target_fields r.item
      @ [
          ("dest", `String r.dest);
          ("offset", `Int r.offset);
          ("length", `Int r.length);
        ]
  | Create r -> destination_fields r.at @ [("exclusive", `Bool r.exclusive)]
  | Write r ->
      target_fields r.at
      @ [("staging", `String r.staging); ("exclusive", `Bool r.exclusive)]
      @ opt "base" (fun b -> `String b) r.base
      @ if r.await then [("await", `Bool true)] else []
  | Mkdir r -> destination_fields r.at @ [("exclusive", `Bool r.exclusive)]
  | Symlink r ->
      destination_fields r.at
      @ [("target", `String r.link_target); ("exclusive", `Bool r.exclusive)]
  | Rename r ->
      (("ref", `String r.src) :: destination_fields r.at)
      @ [("noreplace", `Bool r.noreplace)]
  | Restore r -> target_fields r.item @ opt "keep" (fun k -> `Float k) r.keep
  | Revert r ->
      target_fields r.item
      @ [
          ("arg", `String (Option.fold ~none:"" ~some:Int64.to_string r.version));
        ]
  | Sync r -> [("arg", `String (if r.full then "full" else ""))]
  | Trash_restore path -> [("path", `String path)]
  | Share r ->
      target_fields r.item
      @ opt "expires" (fun e -> `Float e) r.expires
      @ opt "token" (fun t -> `String t) r.token
  | Share_revoke s | Share_preview s -> [("arg", `String s)]
  | Job r -> [("job", Jobs.to_yojson r.job); ("narrate", `Bool r.narrate)]
  | Cancel id -> [("job", `Int id)]
  | Pause on -> [("arg", `String (if on then "on" else "off"))]
  | Stats args -> [("arg", `String (String.concat "," args))]

let encode ?domain r =
  `Assoc
    ((("action", `String (action r)) :: opt "domain" (fun d -> `String d) domain)
    @ request_fields r)

let decode j =
  match required j "action" with
    | "ping" -> Request Ping
    | "stat" -> Request (Stat (target_of j))
    | "list_dir" ->
        Request
          (List_dir
             {
               dir = target_of j;
               after = str j "after";
               limit = int j "limit";
               pull =
                 (match str j "pull" with
                   | None -> `Auto
                   | Some "now" -> `Now
                   | Some "never" -> `Never
                   | Some p -> Fail.invalid "unknown pull %S" p);
             })
    | "list_all" ->
        Request (List_all { after = str j "after"; limit = int j "limit" })
    | "cursor" -> Request Cursor
    | "changes_since" ->
        Request
          (Changes_since { anchor = required j "arg"; limit = int j "limit" })
    | "ensure_cached" ->
        Request (Ensure_cached { item = target_of j; dest = required j "dest" })
    | "fetch_range" ->
        Request
          (Fetch_range
             {
               item = target_of j;
               dest = required j "dest";
               offset = Option.value ~default:(-1) (int j "offset");
               length = Option.value ~default:0 (int j "length");
             })
    | "download_progress" -> Request (Download_progress (target_of j))
    | "create" ->
        Request
          (Create { at = destination_of j; exclusive = flag j "exclusive" })
    | "write" ->
        Request
          (Write
             {
               at = target_of j;
               staging = required j "staging";
               base = str j "base";
               exclusive = flag j "exclusive";
               await = flag j "await";
             })
    | "mkdir" ->
        Request
          (Mkdir { at = destination_of j; exclusive = flag j "exclusive" })
    | "symlink" ->
        Request
          (Symlink
             {
               at = destination_of j;
               link_target = required j "target";
               exclusive = flag j "exclusive";
             })
    | "rename" ->
        Request
          (Rename
             {
               src = required j "ref";
               at = destination_of j;
               noreplace = flag j "noreplace" || flag j "exclusive";
             })
    | "delete" -> Request (Delete (target_of j))
    | "rmdir" -> Request (Rmdir (target_of j))
    | "evict" -> Request (Evict (target_of j))
    | "restore" ->
        Request (Restore { item = target_of j; keep = number j "keep" })
    | "revert" ->
        let version =
          match str j "arg" with
            | None | Some "" -> None
            | Some v -> (
                match Int64.of_string_opt v with
                  | Some ns -> Some ns
                  | None -> Fail.invalid "version must be a timestamp")
        in
        Request (Revert { item = target_of j; version })
    | "full_resync" -> Request Full_resync
    | "sync" -> Request (Sync { full = str j "arg" = Some "full" })
    | "trash_restore" -> (
        match str j "path" with
          | Some p -> Request (Trash_restore p)
          | None -> Fail.invalid "trash_restore needs a path")
    | "share" ->
        Request
          (Share
             {
               item =
                 (match str j "ref" with
                   | Some r -> Ref r
                   | None -> Rel (Option.value ~default:"" (str j "rel")));
               expires = number j "expires";
               token = str j "token";
             })
    | "share_revoke" -> Request (Share_revoke (required j "arg"))
    | "share_preview" -> Request (Share_preview (required j "arg"))
    | "share_clear_cache" -> Request Share_clear_cache
    | "job" -> (
        match Option.map Jobs.of_yojson (member j "job") with
          | Some (Ok job) -> Request (Job { job; narrate = flag j "narrate" })
          | Some (Error e) -> Fail.invalid "unreadable job: %s" e
          | None -> Fail.invalid "job needs a job")
    | "cancel" -> (
        match int j "job" with
          | Some id -> Request (Cancel id)
          | None -> Fail.invalid "cancel needs a job")
    | "retry" -> Request Retry
    | "poll" -> Request Poll
    | "notify_reset" -> Request Notify_reset
    | "status" -> Request Status
    | "pause" -> Request (Pause (str j "arg" <> Some "off"))
    | "stats" ->
        Request
          (Stats
             (List.filter (( <> ) "")
                (String.split_on_char ','
                   (Option.value ~default:"" (str j "arg")))))
    | "stop" -> Request Stop
    | a -> Fail.invalid "unknown action: %s" a

let kind_name = function
  | `Dir -> "dir"
  | `File -> "file"
  | `Symlink -> "symlink"

let row_fields r =
  [
    ("ref", `String r.ref_);
    ("parentRef", `String r.parent_ref);
    ("name", `String r.name);
    ("kind", `String (kind_name r.kind));
    ("size", `Int r.size);
    ("mtime", `Float r.mtime);
    ("etag", `String r.etag);
    ("isUploaded", `Bool r.is_uploaded);
  ]
  @ opt "contentId" (fun c -> `String c) r.content_id
  @ opt "symlinkTarget" (fun t -> `String t) r.symlink_target
  @ (if r.read_only then [("readOnly", `Bool true)] else [])
  @
    match r.availability with
    | None -> []
    | Some Online_only -> [("availability", `String "online-only")]
    | Some Cached -> [("availability", `String "cached")]
    | Some (Pinned until) ->
        [("availability", `String "pinned"); ("pinnedUntil", `Float until)]

let row_of_fields j =
  {
    ref_ = required j "ref";
    parent_ref = required j "parentRef";
    name = required j "name";
    kind =
      (match str j "kind" with
        | Some "dir" -> `Dir
        | Some "symlink" -> `Symlink
        | _ -> `File);
    size = Option.value ~default:0 (int j "size");
    mtime = Option.value ~default:0. (number j "mtime");
    etag = Option.value ~default:"" (str j "etag");
    is_uploaded = flag j "isUploaded";
    content_id = str j "contentId";
    symlink_target = str j "symlinkTarget";
    read_only = flag j "readOnly";
    availability =
      (match str j "availability" with
        | Some "online-only" -> Some Online_only
        | Some "cached" -> Some Cached
        | Some "pinned" ->
            Some (Pinned (Option.value ~default:0. (number j "pinnedUntil")))
        | _ -> None);
  }

let ok fields = `Assoc (("ok", `Bool true) :: fields)
let item r = [("item", `Assoc (row_fields r))]
let item_opt = function Some r -> item r | None -> []

let feed_op_to_json = function
  | Put_op o ->
      `Assoc
        ([
           ("op", `String "put");
           ("ref", `String o.ref_);
           ("parentRef", `String o.parent_ref);
           ("name", `String o.name);
         ]
        @ item_opt o.item)
  | Delete_op o ->
      `Assoc
        [
          ("op", `String "delete");
          ("ref", `String o.ref_);
          ("parentRef", `String o.parent_ref);
          ("name", `String o.name);
        ]
  | Mkdir_op o ->
      `Assoc
        ([
           ("op", `String "mkdir");
           ("ref", `String o.ref_);
           ("parentRef", `String o.parent_ref);
           ("name", `String o.name);
         ]
        @ item_opt o.item)
  | Rmdir_op o ->
      `Assoc
        [
          ("op", `String "rmdir");
          ("id", `String o.id);
          ("ref", `String o.ref_);
          ("parentRef", `String o.parent_ref);
          ("name", `String o.name);
        ]
  | Rename_op o ->
      `Assoc
        ([("op", `String "rename"); ("is_dir", `Bool o.is_dir)]
        @ opt "id" (fun i -> `String i) o.id
        @ [
            ("srcRef", `String o.src_ref);
            ("srcParentRef", `String o.src_parent_ref);
            ("ref", `String o.ref_);
            ("parentRef", `String o.parent_ref);
            ("name", `String o.name);
          ]
        @ item_opt o.item)

let feed_op_of_json j =
  let item = Option.map row_of_fields (member j "item") in
  let ref_ = required j "ref"
  and parent_ref = required j "parentRef"
  and name = required j "name" in
  match required j "op" with
    | "put" -> Put_op { ref_; parent_ref; name; item }
    | "delete" -> Delete_op { ref_; parent_ref; name }
    | "mkdir" -> Mkdir_op { ref_; parent_ref; name; item }
    | "rmdir" -> Rmdir_op { id = required j "id"; ref_; parent_ref; name }
    | "rename" ->
        Rename_op
          {
            is_dir = flag j "is_dir";
            id = str j "id";
            src_ref = required j "srcRef";
            src_parent_ref = required j "srcParentRef";
            ref_;
            parent_ref;
            name;
            item;
          }
    | o -> Fail.invalid "unknown feed op %s" o

let page_fields (pg : page) =
  [("items", `List (List.map (fun r -> `Assoc (row_fields r)) pg.items))]
  @ opt "next" (fun n -> `String n) pg.next
  @ (if pg.unnamed > 0 then [("unnamed", `Int pg.unnamed)] else [])
  @ opt "pulledAt" (fun at -> `Int (int_of_float at)) pg.pulled_at
  @ if pg.outdated then [("outdated", `Bool true)] else []

let encode_reply : type a. a request -> a -> Yojson.Safe.t =
 fun req reply ->
  match req with
    | Ping | Full_resync | Poll | Stop | Delete _ | Rmdir _ | Revert _ -> ok []
    | Stat _ -> ok (row_fields reply)
    | Create _ -> ok (item reply)
    | Mkdir _ -> ok (item reply)
    | Symlink _ -> ok (item reply)
    | Rename _ -> ok (item reply)
    | List_dir _ -> ok (page_fields reply)
    | List_all _ -> (
        match reply with
          | Walk_stale -> ok [("stale", `Bool true)]
          | Listed pg -> ok (page_fields pg))
    | Cursor -> ok [("cursor", `String reply)]
    | Changes_since _ -> (
        match reply with
          | Stale -> ok [("stale", `Bool true)]
          | Changes c ->
              ok
                ([
                   ("stale", `Bool false);
                   ("cursor", `String c.cursor);
                   ("more", `Bool c.more);
                   ("ops", `List (List.map feed_op_to_json c.ops));
                 ]
                @ if c.unnamed > 0 then [("unnamed", `Int c.unnamed)] else []))
    | Ensure_cached _ ->
        ok (("localPath", `String reply.local_path) :: item reply.item)
    | Fetch_range _ ->
        ok
          ([
             ("localPath", `String reply.local_path);
             ("offset", `Int reply.offset);
             ("length", `Int reply.length);
           ]
          @ item reply.item)
    | Download_progress _ -> (
        match reply with
          | Inactive -> ok [("active", `Bool false)]
          | Active a ->
              ok
                [
                  ("active", `Bool true);
                  ("bytesDownloaded", `Int a.downloaded);
                  ("totalBytes", `Int a.total);
                ])
    | Write _ ->
        ok
          ([("size", `Int reply.size); ("mtime", `Float reply.mtime)]
          @ item reply.item)
    | Evict _ ->
        ok [("evicted", `Int reply.succeeded); ("failed", `Int reply.failed)]
    | Restore _ ->
        ok [("restored", `Int reply.succeeded); ("failed", `Int reply.failed)]
    | Trash_restore _ -> (
        match reply with
          | Restored n ->
              ok [("outcome", `String "restored"); ("announced", `Int n)]
          | Not_in_trash -> ok [("outcome", `String "not_in_trash")]
          | Name_taken -> ok [("outcome", `String "name_taken")])
    | Sync _ -> (
        match reply with
          | Incremental n ->
              ok [("mode", `String "incremental"); ("applied", `Int n)]
          | Full f ->
              ok
                [
                  ("mode", `String "full");
                  ("manifests", `Int f.manifests);
                  ("failed", `Int f.failed);
                ])
    | Share _ ->
        ok [("url", `String reply.url); ("expires", `Float reply.expires)]
    | Share_revoke _ -> ok [("revoked", `Bool reply)]
    | Share_preview _ -> (
        match reply with
          | `Made -> ok [("made", `Bool true)]
          | `Not_made why -> ok [("made", `Bool false); ("reason", `String why)]
        )
    | Share_clear_cache ->
        let n, bytes = reply in
        ok [("deleted", `Int n); ("bytes", `Int bytes)]
    | Job _ -> ok [("exit", `Int reply)]
    | Cancel _ -> ok [("cancelled", `Bool reply)]
    | Retry -> ok [("readopted", `Int reply)]
    | Notify_reset -> ok [("delivered", `Int reply)]
    | Status ->
        let transfers l = `List (List.map transfer_to_yojson l) in
        ok
          ([
             ("domain", `String reply.domain);
             ("running", `Bool true);
             ("readOnly", `Bool reply.read_only);
             ("paused", `Bool reply.paused);
             ("pendingUploads", `Int reply.pending_uploads);
             ("pendingDownloads", `Int reply.pending_downloads);
             ("uploading", transfers reply.uploading);
             ("downloading", transfers reply.downloading);
             ("pendingBytes", `Int reply.pending_bytes);
             ("subscribers", `Int reply.subscribers);
             ("traffic", R.traffic_to_yojson reply.traffic);
           ]
          @ (if reply.unnamed > 0 then [("unnamed", `Int reply.unnamed)] else [])
          @ opt "mount" (fun m -> `String m) reply.mount)
    | Pause _ -> ok [("paused", `Bool reply)]
    | Stats _ -> (
        match R.answer_to_yojson reply with `Assoc l -> ok l | j -> j)

let failure_of_reply j =
  match member j "ok" with
    | Some (`Bool true) -> None
    | _ ->
        let text k =
          match member j k with Some (`String s) -> Some s | _ -> None
        in
        Some
          (Fail.make
             (Fail.kind_of_code
                (Option.value ~default:"internal" (text "code")))
             (Option.value ~default:"failed" (text "error")))

let count k j = Option.value ~default:0 (int j k)

let page_of j =
  {
    items =
      (match member j "items" with
        | Some (`List l) -> List.map row_of_fields l
        | _ -> []);
    next = str j "next";
    unnamed = count "unnamed" j;
    pulled_at = Option.map float_of_int (int j "pulledAt");
    outdated = flag j "outdated";
  }

let decode_reply : type a. a request -> Yojson.Safe.t -> a =
 fun req j ->
  Option.iter (fun f -> raise (Fail.E f)) (failure_of_reply j);
  let item () =
    match member j "item" with
      | Some i -> row_of_fields i
      | None -> Fail.invalid "the reply has no item"
  in
  match req with
    | Ping -> ()
    | Full_resync -> ()
    | Revert _ -> ()
    | Poll -> ()
    | Stop -> ()
    | Delete _ -> ()
    | Rmdir _ -> ()
    | Stat _ -> row_of_fields j
    | Create _ -> item ()
    | Mkdir _ -> item ()
    | Symlink _ -> item ()
    | Rename _ -> item ()
    | List_dir _ -> page_of j
    | List_all _ -> if flag j "stale" then Walk_stale else Listed (page_of j)
    | Cursor -> required j "cursor"
    | Changes_since _ ->
        if flag j "stale" then Stale
        else
          Changes
            {
              cursor = required j "cursor";
              more = flag j "more";
              ops =
                (match member j "ops" with
                  | Some (`List l) -> List.map feed_op_of_json l
                  | _ -> []);
              unnamed = count "unnamed" j;
            }
    | Ensure_cached _ -> { local_path = required j "localPath"; item = item () }
    | Fetch_range _ ->
        {
          local_path = required j "localPath";
          offset = count "offset" j;
          length = count "length" j;
          item = item ();
        }
    | Download_progress _ ->
        if flag j "active" then
          Active
            {
              downloaded = count "bytesDownloaded" j;
              total = count "totalBytes" j;
            }
        else Inactive
    | Write _ ->
        {
          size = count "size" j;
          mtime = Option.value ~default:0. (number j "mtime");
          item = item ();
        }
    | Evict _ -> { succeeded = count "evicted" j; failed = count "failed" j }
    | Restore _ -> { succeeded = count "restored" j; failed = count "failed" j }
    | Trash_restore _ -> (
        match str j "outcome" with
          | Some "restored" -> Restored (count "announced" j)
          | Some "not_in_trash" -> Not_in_trash
          | _ -> Name_taken)
    | Sync _ ->
        if str j "mode" = Some "full" then
          Full { manifests = count "manifests" j; failed = count "failed" j }
        else Incremental (count "applied" j)
    | Share _ ->
        {
          url = Option.value ~default:"" (str j "url");
          expires = Option.value ~default:0. (number j "expires");
        }
    | Share_revoke _ -> flag j "revoked"
    | Share_preview _ ->
        if flag j "made" then `Made
        else `Not_made (Option.value ~default:"" (str j "reason"))
    | Share_clear_cache -> (count "deleted" j, count "bytes" j)
    | Job _ -> count "exit" j
    | Cancel _ -> flag j "cancelled"
    | Retry -> count "readopted" j
    | Notify_reset -> count "delivered" j
    | Status ->
        let transfers k =
          match member j k with
            | Some (`List l) ->
                List.filter_map
                  (fun t -> Result.to_option (transfer_of_yojson t))
                  l
            | _ -> []
        in
        let traffic =
          match Option.map R.traffic_of_yojson (member j "traffic") with
            | Some (Ok tr) -> tr
            | _ ->
                { up_bytes = 0; up_rate = 0.; down_bytes = 0; down_rate = 0. }
        in
        {
          domain = Option.value ~default:"" (str j "domain");
          read_only = flag j "readOnly";
          paused = flag j "paused";
          pending_uploads = count "pendingUploads" j;
          pending_downloads = count "pendingDownloads" j;
          uploading = transfers "uploading";
          downloading = transfers "downloading";
          pending_bytes = count "pendingBytes" j;
          subscribers = count "subscribers" j;
          unnamed = count "unnamed" j;
          traffic;
          mount = str j "mount";
        }
    | Pause _ -> flag j "paused"
    | Stats _ -> (
        match R.answer_of_yojson j with
          | Ok a -> a
          | Error e -> Fail.invalid "unreadable stats: %s" e)

type line =
  | Started of int
  | Out of string
  | Narration of string
  | Progress of { text : string; fraction : float option }

let line_to_json = function
  | Started id -> `Assoc [("stream", `String "started"); ("job", `Int id)]
  | Out s -> `Assoc [("stream", `String "out"); ("text", `String s)]
  | Narration s -> `Assoc [("stream", `String "narrate"); ("text", `String s)]
  | Progress { text; fraction } ->
      `Assoc
        ([("stream", `String "progress"); ("text", `String text)]
        @ opt "fraction" (fun f -> `Float f) fraction)

let line_of_json j =
  match (str j "stream", str j "text", int j "job") with
    | Some "started", _, Some id -> Some (Started id)
    | Some "out", Some s, _ -> Some (Out s)
    | Some "narrate", Some s, _ -> Some (Narration s)
    | Some "progress", Some text, _ ->
        Some (Progress { text; fraction = number j "fraction" })
    | _ -> None

let call : type a.
    ?bulk:bool ->
    ?timeout:float ->
    ?domain:string ->
    ?on_line:(line -> unit) ->
    string ->
    a request ->
    a =
 fun ?(bulk = false) ?timeout ?domain ?(on_line = ignore) socket req ->
  let json = encode ?domain req in
  decode_reply req
    (match req with
      | Job _ ->
          Tsync_ipc.Ipc.call_stream socket json ~on_line:(fun j ->
              Option.iter on_line (line_of_json j))
      | _ when bulk -> Tsync_ipc.Ipc.call_bulk socket json
      | _ -> Tsync_ipc.Ipc.call ?timeout socket json)
