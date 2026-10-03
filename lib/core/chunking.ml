let count ~size ~cs = if size <= 0 || cs <= 0 then 0 else (size + cs - 1) / cs
let manifest_count ~size ~cs = max 1 (count ~size ~cs)
let offset ~cs i = i * cs
let length ~size ~cs i = max 0 (min cs (size - (i * cs)))
let index ~cs pos = pos / cs

type piece = { index : int; off : int; len : int; buf_off : int }

let pieces ~cs ~count ~off ~len =
  if cs <= 0 || len <= 0 || off < 0 then []
  else (
    let stop = min (off + len) (count * cs) in
    let rec go pos acc =
      if pos >= stop then List.rev acc
      else (
        let i = pos / cs in
        let in_chunk = pos - (i * cs) in
        let l = min (cs - in_chunk) (stop - pos) in
        go (pos + l)
          ({ index = i; off = in_chunk; len = l; buf_off = pos - off } :: acc))
    in
    go off [])

let default_chunk_size = 8 * 1024 * 1024
let chunk_size_min = 256 * 1024
let chunk_size_max = 256 * 1024 * 1024
let chunk_size_read_max = 0x7fffffff
