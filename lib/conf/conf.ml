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

  val cache_root : string
  val data_dir : string
  val socket_path : string
  val notify_path : string

  (** Max files uploaded concurrently (upload worker count). *)
  val max_uploads : int

  (** Max files downloaded concurrently. *)
  val max_downloads : int

  (** Chunk size (bytes) for newly uploaded files in this domain. Existing files
      keep the chunk size recorded in their own manifest, so changing this only
      affects files created afterwards. Smaller chunks cut read/write
      amplification for random access at the cost of larger manifests and more
      backend requests. *)
  val chunk_size : int

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
