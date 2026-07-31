PROJ      = tsync.xcodeproj
# Propagate -jN from make invocation; fall back to 12
MAKE_JOBS = $(patsubst -j%,%,$(filter -j%,$(MAKEFLAGS)))
JOBS      = $(if $(MAKE_JOBS),$(MAKE_JOBS),12)

.PHONY: all generate build package deploy install clean

all: build

## Regenerate the Xcode project from project.yml (run after editing project.yml)
generate:
	xcodegen generate

## Build a complete TsyncApp.app: app + extension + embedded OCaml daemon
build:
	JOBS=$(JOBS) ./build.sh

## Build a signed, notarized dist/tsync.dmg (needs Developer ID credentials)
package:
	JOBS=$(JOBS) ./package.sh

## Build and install TsyncApp to /Applications
deploy install:
	JOBS=$(JOBS) ./deploy.sh

clean:
	xcodebuild -project $(PROJ) -scheme TsyncApp clean
	rm -rf dist

# End-to-end check against a real File Provider replica. Stages its own domain
# (store daemon, config entry, second client) and takes it down again, so it
# needs the app installed but no manual setup. Not part of `dune test`: it
# restarts the app and registers a domain.
e2e:
	cd .. && dune build bin/tsync.exe tests/e2e/macos/e2e_macos.exe && ./_build/default/tests/e2e/macos/e2e_macos.exe

.PHONY: e2e
