include Cache_layout

include
  Cache_layout.Make
    (Io_lwt.Core)
    (struct
      let file_exists = Io_lwt.Retry.file_exists
      let atomic_write = Io_lwt.Fs.atomic_write
      let read_file_opt = Io_lwt.Fs.read_file_opt
      let rm_rf = Io_lwt.Fs.rm_rf
    end)
