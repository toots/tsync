include Chunk_cache

module Make =
  Chunk_cache.Make (Io_lwt.Core) (Io_lwt.Fs) (Io_lwt.Retry) (Io_lwt.Bounded)
