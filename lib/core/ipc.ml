let data_dir () =
  match Sys.getenv_opt "XDG_DATA_HOME" with
    | Some d -> Filename.concat d "tsync"
    | None -> Filename.concat (Sys.getenv "HOME") ".local/share/tsync"

let socket_path () = Filename.concat (data_dir ()) "tsync.sock"
let auto_evict_path () = Filename.concat (data_dir ()) "auto-evict"

(* ── Client ──────────────────────────────────────────────────────────────── *)

let send cmd =
  let path = socket_path () in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX path);
  let ic = Unix.in_channel_of_descr fd in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc (cmd ^ "\n");
  flush oc;
  let resp = input_line ic in
  Unix.close fd;
  resp

(* ── Server ──────────────────────────────────────────────────────────────── *)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Split "CMD rest of line" on first space only *)
let split_cmd line =
  match String.index_opt line ' ' with
    | None -> (line, "")
    | Some i ->
        ( String.sub line 0 i,
          String.sub line (i + 1) (String.length line - i - 1) )

type command =
  | Stop
  | Status
  | Evict of string
  | Restore of string
  | Auto_evict of string
  | Full_resync

let parse_command line =
  let cmd, arg = split_cmd (String.trim line) in
  match cmd with
    | "STOP" -> Stop
    | "STATUS" -> Status
    | "EVICT" -> Evict arg
    | "RESTORE" -> Restore arg
    | "AUTO_EVICT" -> Auto_evict arg
    | "FULL_RESYNC" -> Full_resync
    | c -> failwith ("ERROR unknown command: " ^ c)

let notify ~path msg =
  (try
     let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     (try
        Unix.connect fd (Unix.ADDR_UNIX path);
        let oc = Unix.out_channel_of_descr fd in
        output_string oc (msg ^ "\n");
        flush oc
      with _ -> ());
     Unix.close fd
   with _ -> ())

let notify_evict ~path key = notify ~path ("EVICT " ^ key)
let notify_uploaded ~path key = notify ~path ("UPLOADED " ^ key)

let serve ~path handler =
  let dir = Filename.dirname path in
  mkdir_p dir;
  (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX path);
  Unix.listen fd 8;
  let running = ref true in
  while !running do
    let client_fd, _ = Unix.accept fd in
    (try
       let ic = Unix.in_channel_of_descr client_fd in
       let oc = Unix.out_channel_of_descr client_fd in
       let line = input_line ic in
       let resp = handler line in
       if resp = "STOP" then running := false;
       output_string oc (resp ^ "\n");
       flush oc
     with _ -> ());
    Unix.close client_fd
  done;
  Unix.close fd;
  try Unix.unlink path with _ -> ()
