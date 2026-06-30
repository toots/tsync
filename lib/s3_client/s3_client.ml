open Lwt.Infix
module S3 = Aws_s3_lwt.S3

exception S3_error of string
exception Cancelled

type file_entry = {
  key : string;
  size : int;
  last_modified : float;
  content_type : string option;
}

type t = {
  bucket : string;
  credentials : Aws_s3.Credentials.t;
  endpoint : Aws_s3.Region.endpoint;
}

let make ~bucket ~region ~access_key_id ~secret_access_key =
  let credentials =
    Aws_s3.Credentials.make ~access_key:access_key_id
      ~secret_key:secret_access_key ()
  in
  let endpoint =
    Aws_s3.Region.endpoint ~inet:`V4 ~scheme:`Https
      (Aws_s3.Region.of_string region)
  in
  { bucket; credentials; endpoint }

let string_of_error = function
  | S3.Redirect _ -> "redirect"
  | S3.Throttled -> "throttled"
  | S3.Unknown (code, msg) -> Printf.sprintf "unknown(%d): %s" code msg
  | S3.Failed exn -> Printexc.to_string exn
  | S3.Forbidden -> "forbidden"
  | S3.Not_found -> "not found"

(* Global mutex: Lwt event loop must run in one thread at a time *)
let lwt_mutex = Mutex.create ()

let lwt_run f =
  Mutex.lock lwt_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock lwt_mutex)
    (fun () -> Lwt_main.run (f ()))

let s3_eio msg = Unix.Unix_error (Unix.EIO, "s3", msg)

let unwrap op = function
  | Ok v -> v
  | Error e ->
      let msg = string_of_error e in
      Log.err "s3 %s: %s" op msg;
      raise (s3_eio msg)

let put t ?content_type ~key ~data () =
  ignore
    (lwt_run (fun () ->
         S3.put ~credentials:t.credentials ~endpoint:t.endpoint ?content_type
           ~bucket:t.bucket ~key ~data ()
         >|= unwrap "put"))

let get t ~key () =
  lwt_run (fun () ->
      S3.get ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= unwrap "get")

let head_opt t ~key () =
  lwt_run (fun () ->
      S3.head ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= function
      | Ok c ->
          Some
            {
              key = c.S3.key;
              size = c.S3.size;
              last_modified = c.S3.last_modified;
              content_type = c.S3.content_type;
            }
      | Error S3.Not_found -> None
      | Error e ->
          let msg = string_of_error e in
          Log.err "s3 head %s: %s" key msg;
          raise (s3_eio msg))

let delete t ~key () =
  lwt_run (fun () ->
      S3.delete ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~key ()
      >|= function
      | Ok _ | Error S3.Not_found -> ()
      | Error e -> raise (s3_eio (string_of_error e)))

let delete_multi t keys =
  let open S3.Delete_multi in
  let rec go = function
    | [] -> ()
    | batch ->
        let n = min 1000 (List.length batch) in
        let here = List.filteri (fun i _ -> i < n) batch in
        let rest = List.filteri (fun i _ -> i >= n) batch in
        let objects = List.map (fun key -> { key; version_id = None }) here in
        ignore
          (lwt_run (fun () ->
               S3.delete_multi ~credentials:t.credentials ~endpoint:t.endpoint
                 ~bucket:t.bucket ~objects ()
               >|= unwrap "delete_multi"));
        go rest
  in
  go keys

let copy t ~src_key ~dst_key () =
  let data = get t ~key:src_key () in
  let content_type =
    match head_opt t ~key:src_key () with
      | Some c -> c.content_type
      | None -> None
  in
  put t ?content_type ~key:dst_key ~data ()

(* List all objects under prefix, paginating through continuations *)
let list_all t ~prefix () =
  let entry_of c =
    {
      key = c.S3.key;
      size = c.S3.size;
      last_modified = c.S3.last_modified;
      content_type = c.S3.content_type;
    }
  in
  let rec collect acc cont =
    match cont with
      | S3.Ls.Done -> Lwt.return acc
      | S3.Ls.More f -> (
          f () >>= function
          | Ok (items, next) -> collect (acc @ List.map entry_of items) next
          | Error e -> Lwt.fail (s3_eio (string_of_error e)))
  in
  lwt_run (fun () ->
      S3.ls ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
        ~prefix ()
      >>= function
      | Ok (items, cont) -> collect (List.map entry_of items) cont
      | Error e ->
          let msg = string_of_error e in
          Log.err "s3 ls %s: %s" prefix msg;
          Lwt.fail (s3_eio msg))

(* Simulate delimiter='/' — returns (files, subdir_names) relative to prefix *)
let list_directory t ~prefix () =
  let prefix_len = String.length prefix in
  let all = list_all t ~prefix () in
  let dirs = Hashtbl.create 16 in
  let files = ref [] in
  List.iter
    (fun e ->
      if String.length e.key <= prefix_len then ()
      else begin
        let rest =
          String.sub e.key prefix_len (String.length e.key - prefix_len)
        in
        match String.index_opt rest '/' with
          | None -> files := e :: !files
          | Some i -> Hashtbl.replace dirs (String.sub rest 0 i) ()
      end)
    all;
  let subdirs = Hashtbl.fold (fun k () acc -> k :: acc) dirs [] in
  (List.rev !files, List.sort String.compare subdirs)
