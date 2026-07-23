(* Manual end-to-end client for a running http-proxy relay. Not part of runtest
   (needs a live server). Usage: proxy_client URL SECRET [rw|ro|backfill] *)
let mode = if Array.length Sys.argv > 3 then Sys.argv.(3) else "rw"

let () =
  let url = Sys.argv.(1) and secret = Sys.argv.(2) in
  let (module B : Backend.S) = Http_proxy_backend.make ~url ~secret in
  Lwt_main.run
    (let open Lwt.Syntax in
     let key = "tsync/testdomain/chunks/live" in
     match mode with
       | "ro" ->
           (* A read-only domain rejects writes (403 → Backend_error). *)
           let* rejected =
             Lwt.catch
               (fun () ->
                 let+ () = B.put ~key ~data:"nope" () in
                 false)
               (fun _ -> Lwt.return true)
           in
           assert rejected;
           (* but reads still work *)
           let* _ = B.list_all ~prefix:"tsync/testdomain/" () in
           print_endline "OK: read-only rejects writes, allows reads";
           Lwt.return_unit
       | "shareurl" ->
           let* u = B.share_url ~prefix:"tsync/testdomain/manifests/" () in
           (match u with
             | Some url -> Printf.printf "OK: share_url = %s\n" url
             | None -> failwith "share_url returned None");
           Lwt.return_unit
       | "backfill" ->
           (* The key was pre-placed only on the primary; a read must serve it and
              (in the background) mirror it into the backfill backend. *)
           let* got = B.get ~key:"tsync/testdomain/chunks/pre" () in
           assert (got = "backfillme");
           print_endline "OK: read served from primary";
           Lwt.return_unit
       | _ ->
           let* () = B.put ~key ~data:"hello world" () in
           let* got = B.get ~key () in
           assert (got = "hello world");
           let* h = B.head_opt ~key () in
           (match h with
             | Some e -> assert (e.Backend.size = 11)
             | None -> failwith "head_opt None for existing key");
           let* miss = B.get_opt ~key:"tsync/testdomain/chunks/nope" () in
           assert (miss = None);
           let* entries = B.list_all ~prefix:"tsync/testdomain/" () in
           assert (
             List.exists (fun (e : Backend.file_entry) -> e.key = key) entries);
           Printf.printf "OK: put/get/head/list/404 all correct (%d entries)\n"
             (List.length entries);
           let (module Bad : Backend.S) =
             Http_proxy_backend.make ~url ~secret:"wrong"
           in
           let* rejected =
             Lwt.catch
               (fun () ->
                 let+ _ = Bad.get ~key () in
                 false)
               (fun _ -> Lwt.return true)
           in
           assert rejected;
           print_endline "OK: wrong secret rejected";
           Lwt.return_unit)
