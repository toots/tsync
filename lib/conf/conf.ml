(* Chunk size for newly uploaded files when neither the config nor the backend
   says otherwise. 8 MiB favors sequential throughput and small manifests; lower
   it for random-access workloads to cut read/write amplification. *)
let default_chunk_size = 8 * 1024 * 1024

(* Cache chunk size when the config does not say. Larger than a stored chunk on
   purpose: this is a disk-latency knob, not a network one, and the two are free
   to differ (see [cache_chunk_size]). *)
let default_cache_chunk_size = 16 * 1024 * 1024

(** What it takes to answer "is every byte of this key on this machine?": the
    cache tree to look in, and the sizes that say which files to look for. Its
    own record because the callers ({!Manifest.is_local} and every frontend) run
    outside a functor, in plain non-Lwt CLI code — and because passing the parts
    one by one meant every new field here touching each of them. *)
type locality = {
  cache_root : string;
  domain_name : string;
  domain_prefix : string;
  cache_chunk_size : int;
}

module type S = sig
  val versioning : bool
  val client_name : string
  val domain_name : string
  val domain_prefix : string
  val chunk_prefix : string
  val versions_prefix : string
  val journal_prefix : string
  val cursor_key : string
  val shares_prefix : string

  (** Ordered list of backends. First element is primary (used for reads).
      Writes fan out to all elements. *)
  val backends : (module Backend.S) list

  (** The individual stores that may serve a share link, in role order.

      A share manifest lives under {!shares_prefix}, outside every domain root,
      so publishing one changes no domain content — which is why a read-only
      domain can still share what it can already read, and why this does not go
      through the write composite in {!backends}. Backfill targets are left out:
      a target is behind by construction, so a link served from one could point
      at something it has not caught up with. *)
  val share_backends : (module Backend.S) list

  val cache_root : string
  val data_dir : string
  val socket_path : string

  (** Max files uploaded concurrently (upload worker count). *)
  val max_uploads : int

  (** Max files downloaded concurrently. *)
  val max_downloads : int

  (** Chunk size (bytes) for newly uploaded files in this domain. Existing files
      keep the chunk size recorded in their own manifest, so changing this only
      affects files created afterwards. Smaller chunks cut read/write
      amplification for random access at the cost of larger manifests and more
      backend requests.

      [None] when the config does not say: the effective size is then whatever
      the primary backend recommends (an http-proxy answers with its own), and
      [default_chunk_size] if it has no opinion either. Resolved once per
      process — see {!Remote.S.chunk_size}. *)
  val chunk_size : int option

  (** Cache chunk size (bytes): the local cache stores consecutive stored chunks
      grouped into files of about this size, the group being the [n] stored
      chunks whose total is closest to it. Storage granularity wants to be small
      (less egress when a file changes), disk granularity wants to be large
      (fewer opens, less I/O latency per read), so the two are set apart. Unlike
      [chunk_size] this is purely local: it is not recorded in any manifest and
      changing it only orphans cache files, which the cap reclaims. [None] means
      [default_cache_chunk_size]. *)
  val cache_chunk_size : int option

  (** Soft cap (bytes) on local cache disk usage for this domain. When set and
      exceeded, the coldest clean, closed files are evicted (dropping their
      local data, refetched on demand) until usage is back under the cap.
      Best-effort; [None] means unbounded. *)
  val max_cache : int option

  (** How [import] treats symbolic links: [`Keep] preserves them as symlink
      objects, [`Follow] dereferences to the target's content, [`Skip] ignores
      them. *)
  val symlink_policy : [ `Keep | `Follow | `Skip ]

  (** When [true], the domain rejects all write operations. *)
  val read_only : bool
end

(** The domain's effective cache chunk size, config value or built-in default.
    One spelling, so no caller can pick a different default by accident. *)
let cache_chunk_size (module C : S) =
  Option.value C.cache_chunk_size ~default:default_cache_chunk_size

let locality (module C : S) =
  {
    cache_root = C.cache_root;
    domain_name = C.domain_name;
    domain_prefix = C.domain_prefix;
    cache_chunk_size = cache_chunk_size (module C);
  }
