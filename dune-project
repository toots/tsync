(lang dune 3.23)
(name tsync)
(generate_opam_files true)
(opam_file_location inside_opam_directory)

(package
 (name tsync)
 (synopsis "S3-backed FUSE filesystem sync tool")
 (maintainers "Romain Beauxis <toots@rastageeks.org>")
 (authors "Romain Beauxis <toots@rastageeks.org>")
 (homepage "https://github.com/toots/tsync")
 (bug_reports "https://github.com/toots/tsync/issues")
 (license MIT)
 (depends
  (ocaml (>= 5.5.0))
  dune
  yojson
  syslog
  lwt
  lwt_ppx
  lwt_ssl
  cmdliner)
 (depopts
  tsync-s3
  tsync-fuse))

(package
   (name tsync-s3)
   (version 1)
   (allow_empty)
   (depends aws-s3-lwt lwt lwt_ppx lwt_ssl)
   (synopsis "Virtual package install tsync S3 dependencies")
)

(package
   (name tsync-fuse)
   (version 1)
   (allow_empty)
   (depends fuse3)
   (synopsis "Virtual package install tsync fuse dependencies")
)
