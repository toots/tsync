.PHONY: build test deploy configure install-deps install uninstall e2e conformance stress

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
	# Without lingering the user manager only runs while a session is open, so a
	# headless box comes back from reboot with nothing started. Needs root, so
	# skip the prompt when it is already set.
	loginctl show-user "$$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' \
	  || sudo loginctl enable-linger "$$USER"

# Every step tolerates already being undone, so a partial install still cleans
# up. Lingering is left enabled: it is a user-wide setting other services may
# depend on, and turning it off is one command if you want it gone.
uninstall:
	-systemctl --user disable --now tsync
	rm -f ~/.config/systemd/user/tsync.service
	-systemctl --user daemon-reload
	rm -f ~/.local/bin/tsync
	-opam remove -y tsync tsync-s3 tsync-fuse

# End-to-end check against a real FUSE mount. Stages everything it needs — a
# store, a mount, a second client — under a scratch directory and takes it all
# down again, touching no shared config and no service. Needs fuse3 and
# permission to mount. Not part of `dune test`: it mounts a filesystem.
e2e:
	cd .. && dune build bin/tsync.exe tests/e2e/linux/e2e_linux.exe && ./_build/default/tests/e2e/linux/e2e_linux.exe

# Talks to real object stores, so it is driven from here rather than from
# `dune runtest`: it needs credentials, and it exits 2 when it was given none
# rather than reporting a pass it did not earn.
conformance:
	cd .. && dune build tests/conformance/conformance.exe && ./_build/default/tests/conformance/conformance.exe

# Concurrent load over two real mounts, judged against an oracle. Prints the
# seed it used; TSYNC_STRESS_SEED replays a run, TSYNC_STRESS_OPS sizes it, and
# TSYNC_STRESS_KEEP leaves the scratch directory behind (a failing run keeps it
# either way).
stress:
	cd .. && dune build bin/tsync.exe tests/e2e/stress/stress.exe && ./_build/default/tests/e2e/stress/stress.exe
