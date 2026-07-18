(lang dune 3.23)
(name tsync)
(generate_opam_files true)
(opam_file_location inside_opam_directory)
 (maintainers "Romain Beauxis <toots@rastageeks.org>")
 (authors "Romain Beauxis <toots@rastageeks.org>")
 (homepage "https://github.com/toots/tsync")
 (bug_reports "https://github.com/toots/tsync/issues")
(license MIT)

(package
 (name tsync)
 (synopsis "Cloud-backed filesystem sync tool")
 (depends
  (ocaml (>= 5.1))
  (tsync-fuse (= :os "linux"))
  dune
  conf-libev
  conf-xxhash
  conduit-lwt-unix
  yojson
  lwt
  lwt_ppx
  mem_usage
tls
  base64
  cmdliner)
 (depopts
   syslog
  tsync-s3))

(package
 (name tsync-s3)
 (version 1)
 (allow_empty)
 (synopsis "Virtual package install tsync S3 dependencies")
 (depends aws-s3-lwt tls-lwt)
 (depopts lwt_ssl)
 )

(package
 (name tsync-fuse)
 (version 1)
 (allow_empty)
 (synopsis "Virtual package install tsync fuse dependencies")
 (depends fuse3))
