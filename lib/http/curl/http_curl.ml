open Tsync_core

(* The bindings' feature list predates libcurl's HTTP/2 flag; nghttp2 is
   libcurl's one HTTP/2 implementation, and its version string names it. *)
let speaks_http2 () =
  List.exists
    (String.starts_with ~prefix:"nghttp2/")
    (String.split_on_char ' ' (Curl.version ()))

(* One handle keeps libcurl's connections to APNs open between pushes; a handle
   serves one call at a time. *)
(* ponytail: one push in flight at a time; a handle pool if a listener ever
   pushes faster than one round trip allows. *)
let lock = Mutex.create ()
let handle = lazy (Curl.init ())

let post ~url ~headers body =
  Mutex.protect lock @@ fun () ->
  let h = Lazy.force handle in
  let answer = Buffer.create 256 in
  Curl.reset h;
  Curl.set_url h url;
  Curl.set_httpversion h Curl.HTTP_VERSION_2TLS;
  Curl.set_post h true;
  Curl.set_postfields h body;
  Curl.set_postfieldsize h (String.length body);
  Curl.set_httpheader h (List.map (fun (k, v) -> k ^ ": " ^ v) headers);
  Curl.set_timeout h 30;
  Curl.set_writefunction h (fun s ->
      Buffer.add_string answer s;
      String.length s);
  match Curl.perform h with
    | () ->
        {
          Tsync_http.Http2.status = Curl.get_responsecode h;
          body = Buffer.contents answer;
        }
    | exception Curl.CurlException (_, _, reason) ->
        Fail.raise_ ~op:"push" Fail.Link "libcurl: %s" reason

let () =
  Curl.global_init Curl.CURLINIT_GLOBALALL;
  if speaks_http2 () then Tsync_http.Http2.register ~name:"libcurl" post
