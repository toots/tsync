open Tsync_core

type rate = {
  m : Mutex.t;
  mutable at : float;
  mutable value : float;
  mutable last : float option;
}

let rate ~now = { m = Mutex.create (); at = now; value = 0.; last = None }

let per_second r ~now v =
  Mutex.protect r.m (fun () ->
      match r.last with
        | Some x when now -. r.at < 1. -> x
        | _ ->
            let x = (v -. r.value) /. Float.max 0.001 (now -. r.at) in
            r.at <- now;
            r.value <- v;
            r.last <- Some x;
            x)

let started_at = Unix.gettimeofday ()
let cpu = rate ~now:started_at

let load_avg () =
  Option.bind (Fs.read_file_opt "/proc/loadavg") (fun s ->
      match String.split_on_char ' ' s with
        | one :: _ -> float_of_string_opt one
        | [] -> None)

let self ?traffic ~role ~serves () : Status_report.self =
  let now = Unix.gettimeofday () in
  let u = Usage.sample () in
  {
    server =
      {
        hostname = Unix.gethostname ();
        pid = Unix.getpid ();
        started_at;
        uptime = now -. started_at;
        load_avg = load_avg ();
        role;
        serves;
      };
    usage =
      {
        cpu_seconds = u.cpu_seconds;
        cpu_percent = 100. *. per_second cpu ~now u.cpu_seconds;
        cpu_percent_avg =
          100. *. u.cpu_seconds /. Float.max 0.001 (now -. started_at);
        rss_bytes = u.resident;
        private_bytes = u.private_;
        swapped_bytes = u.swapped;
        anonymous_bytes = u.anonymous;
        file_backed_bytes = u.file_backed;
        heap_bytes = u.heap;
        top_heap_bytes = u.top_heap;
        minor_collections = u.minor_collections;
        major_collections = u.major_collections;
      };
    uplinks = Tsync_store.Uplink.status ();
    traffic;
    recent_errors =
      List.map
        (fun (t, level, message) -> { Status_report.t; level; message })
        (Log.recent ());
  }
