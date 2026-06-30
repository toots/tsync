PROJ      = tsync.xcodeproj
# Propagate -jN from make invocation; fall back to 12
MAKE_JOBS = $(patsubst -j%,%,$(filter -j%,$(MAKEFLAGS)))
JOBS      = $(if $(MAKE_JOBS),$(MAKE_JOBS),12)
XFLAGS    = -project $(PROJ) -jobs $(JOBS) CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates

.PHONY: all generate build deploy deploy-daemon install configure clean

all: build

## Regenerate the Xcode project from project.yml (run after editing project.yml)
generate:
	xcodegen generate

## Build TsyncApp (Release)
build:
	xcodebuild $(XFLAGS) -scheme TsyncApp -configuration Release -destination 'platform=macOS'

## Build and install TsyncApp to /Applications
deploy:
	./deploy.sh

## Build and install the OCaml daemon + launchd plist
deploy-daemon:
	./deploy-daemon.sh

install: deploy deploy-daemon

## Interactive first-time setup (bucket, credentials, config.json)
configure:
	./configure.sh

clean:
	xcodebuild $(XFLAGS) -scheme TsyncApp clean
