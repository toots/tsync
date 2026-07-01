.PHONY: build test deploy configure install-deps install test-lifecycle

CASES      ?=
SKIP_BUILD ?=

build:
	dune build

test:
	dune test

deploy: build
	./deploy.sh

configure:
	./configure.sh

install-deps:
	opam pin add -ny fuse3 git+https://github.com/toots/ocamlfuse.git
	opam pin add -ny aws-s3-lwt git+https://github.com/toots/aws-s3.git
	opam install --deps-only -y ..

install:
	opam install ..
	mkdir -p ~/.local/bin
	ln -sf "$$(opam var bin)/tsync" ~/.local/bin/tsync
	mkdir -p ~/.config/systemd/user
	cp tsync.service ~/.config/systemd/user/
	systemctl --user daemon-reload
	systemctl --user enable tsync
	systemctl --user restart tsync

test-lifecycle:
	./test_lifecycle.sh \
	  $(if $(SKIP_BUILD),--skip-build) \
	  $(CASES)
