(* Used when neither the config nor the backend says otherwise. 8 MiB favors
   sequential throughput and small manifests; lower it for random access to cut
   read/write amplification. *)
let default_chunk_size = 8 * 1024 * 1024

(* Deliberately larger than a stored chunk: this is a disk-latency knob, not a
   network one (see [cache_chunk_size]). *)
let default_cache_chunk_size = 16 * 1024 * 1024

(** What it takes to answer "is every byte of this key on this machine?": the
    cache tree to look in and the sizes saying which files to look for. Its own
    record because the callers ({!Manifest.is_local} and every frontend) run
    outside a functor, in plain non-Lwt CLI code. *)
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

  (** The domain's stores as one: reads walk them in order, a write lands on the
      mains and the deferred targets catch up behind it. Everything that reads
      or writes a domain key goes through this and nothing else. *)
  val store : (module Backend.S)

  (** The same stores individually, in role order, for the callers that need one
      rather than the domain: a report naming each, a resync copying between
      two, a share link choosing where to point.

      A share manifest lives under {!shares_prefix}, outside every domain root,
      so publishing one changes no domain content — which is why it goes to a
      member directly rather than through {!store}, and why a read-only domain
      can share what it can already read. *)
  val members : Backend.member list

  val cache_root : string
  val data_dir : string
  val socket_path : string

  (** Max files uploaded concurrently (upload worker count). *)
  val max_uploads : int

  (** Max chunk bodies held in memory at once, across every upload. Times the
      chunk size, this is what the upload path costs in memory. *)
  val max_chunk_buffers : int

  (** Max files downloaded concurrently. *)
  val max_downloads : int

  (** Chunk size (bytes) for newly uploaded files. Existing files keep the size
      recorded in their own manifest, so changing this only affects files
      created afterwards. Smaller chunks cut read/write amplification for random
      access at the cost of larger manifests and more backend requests.

      [None] when the config does not say: the effective size is then what the
      primary backend recommends (an http-proxy answers with its own), else
      [default_chunk_size]. Resolved once per process — see
      {!Remote.S.chunk_size}. *)
  val chunk_size : int option

  (** Cache chunk size (bytes): the local cache groups consecutive stored chunks
      into files of about this size, the group being the [n] chunks whose total
      is closest to it. Storage granularity wants to be small (less egress when
      a file changes) and disk granularity large (fewer opens, less latency per
      read), hence two settings. Purely local: not recorded in any manifest, and
      changing it only orphans cache files, which the cap reclaims. [None] means
      [default_cache_chunk_size]. *)
  val cache_chunk_size : int option

  (** Soft cap (bytes) on local cache disk usage. When exceeded, the coldest
      clean, closed files are evicted and re-fetched on demand until usage is
      back under it. Best-effort; [None] is unbounded. *)
  val max_cache : int option

  (** How [import] treats symbolic links: [`Keep] preserves them as symlink
      objects, [`Follow] dereferences to the target's content, [`Skip] ignores
      them. *)
  val symlink_policy : [ `Keep | `Follow | `Skip ]

  (** When [true], the domain rejects all write operations. *)
  val read_only : bool
end

(** The domain's effective cache chunk size: config value or built-in default.
    One spelling, so no caller picks a different default by accident. *)
let cache_chunk_size (module C : S) =
  Option.value C.cache_chunk_size ~default:default_cache_chunk_size

let locality (module C : S) =
  {
    cache_root = C.cache_root;
    domain_name = C.domain_name;
    domain_prefix = C.domain_prefix;
    cache_chunk_size = cache_chunk_size (module C);
  }
