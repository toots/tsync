open Tsync_core
open Tsync_http

let p fmt = Printf.printf (fmt ^^ "\n%!")

let pattern n =
  let b = Bigstring.create n in
  for i = 0 to n - 1 do
    Bigarray.Array1.set b i (Char.chr (i * 7 mod 251))
  done;
  b

let large = pattern (1024 * 1024)
let chunked = pattern (600 * 1024)

let handler (r : Server.request) _ : Server.response =
  match r.path with
    | "/large" -> { status = 200; headers = []; body = Bigstring large }
    | "/chunked" ->
        {
          status = 200;
          headers = [];
          body =
            Server.stream (fun w ->
                List.iter
                  (fun off -> w (Bigstring.sub chunked ~off ~len:(100 * 1024)))
                  [0; 102400; 204800; 307200; 409600; 512000]);
        }
    | "/small" -> Server.text 200 "small"
    | "/small-chunked" ->
        {
          status = 200;
          headers = [];
          body = Server.stream (fun w -> w (Bigstring.of_string "small"));
        }
    | "/missing" -> { status = 404; headers = []; body = Bigstring large }
    | _ -> Server.text 404 "not found"

(* The mappings of files under [dir]: what tells a spilled body from one held
   in memory, which a byte comparison cannot. *)
let mappings_under dir =
  In_channel.with_open_text "/proc/self/maps" In_channel.input_lines
  |> List.filter (fun l -> Text.contains l (dir ^ "/"))
  |> List.length

let () =
  Rt.run_sync (fun () ->
      let dir = Filename.concat (Sys.getcwd ()) "spill" in
      Fs.mkdir_p dir;
      let dead =
        let pid =
          Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout
            Unix.stderr
        in
        ignore (Unix.waitpid [] pid);
        pid
      in
      let stale =
        Filename.concat dir (Printf.sprintf ".tsync-tmp-%d-1.tmp" dead)
      in
      Out_channel.with_open_bin stale (fun _ -> ());
      let fresh = Fs.temp_in dir in
      Out_channel.with_open_bin fresh (fun _ -> ());
      let server =
        Server.serve [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)] handler
      in
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let e =
        Client.endpoint ~spill:dir (Printf.sprintf "http://127.0.0.1:%d" port)
      in
      p "nothing is swept before a body spills: %b" (Sys.file_exists stale);
      let get ?max_body path expected =
        let before = mappings_under dir in
        match Client.request ?max_body e ~meth:"GET" path with
          | r ->
              p "%s: %d, %d bytes, same bytes %b, mapped %b" path r.status
                (Bigstring.length r.body)
                (Bigstring.equal r.body expected)
                (mappings_under dir > before)
          | exception Fail.E f ->
              p "%s: %s: %s" path (Fail.kind_name f.kind) f.reason
      in
      get "/large" large;
      p "a stale temporary is swept: %b" (not (Sys.file_exists stale));
      p "a fresh temporary is kept: %b" (Sys.file_exists fresh);
      Sys.remove fresh;
      get "/chunked" chunked;
      get "/small" (Bigstring.of_string "small\n");
      get "/small-chunked" (Bigstring.of_string "small");
      get "/missing" large;
      get ~max_body:1000 "/large" large;
      p "the spill directory is empty: %b" (Fs.readdir dir = []);
      Server.close ~grace:0.1 server)
