.PHONY: build test deploy configure install-deps install e2e

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
	opam pin add -ny git+https://github.com/toots/aws-s3.git#tsync
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

# End-to-end check against a real FUSE mount. Stages everything it needs — a
# store, a mount, a second client — under a scratch directory and takes it all
# down again, touching no shared config and no service. Needs fuse3 and
# permission to mount. Not part of `dune test`: it mounts a filesystem.
e2e:
	cd .. && dune build bin/tsync.exe tests/e2e/linux/e2e_linux.exe && ./_build/default/tests/e2e/linux/e2e_linux.exe
