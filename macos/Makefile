PROJ      = tsync.xcodeproj
# Propagate -jN from make invocation; fall back to 12
MAKE_JOBS = $(patsubst -j%,%,$(filter -j%,$(MAKEFLAGS)))
JOBS      = $(if $(MAKE_JOBS),$(MAKE_JOBS),12)
XFLAGS    = -project $(PROJ) -jobs $(JOBS) CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates

.PHONY: all generate build build-app build-cli test deploy install configure test-lifecycle clean

all: build

## Regenerate the Xcode project from project.yml (run after editing project.yml)
generate:
	xcodegen generate

## Build both TsyncApp and the tsync CLI (Release)
build: build-app build-cli

build-app:
	xcodebuild $(XFLAGS) -scheme TsyncApp -configuration Release -destination 'platform=macOS'

build-cli:
	xcodebuild $(XFLAGS) -scheme tsync -configuration Release

## Run unit tests (Journal encode/decode/sync logic)
test:
	xcodebuild test $(XFLAGS) -scheme TsyncTests -destination 'platform=macOS'

## Build, install to /Applications, and restart the daemon
deploy:
	./deploy.sh

install: deploy

## Interactive first-time setup (bucket, credentials, config.json)
configure:
	./configure.sh

## Full integration test suite: builds, installs, starts daemon, tests against a real S3 bucket
## Pass CASES= to run specific cases, e.g.: make test-lifecycle CASES="1 3"
## Pass SKIP_BUILD=1 to skip xcodebuild+install, e.g.: make test-lifecycle SKIP_BUILD=1 CASES="6 7"
test-lifecycle:
	./test_lifecycle.sh $(if $(SKIP_BUILD),--skip-build) $(CASES)

clean:
	xcodebuild $(XFLAGS) -scheme TsyncApp clean
	xcodebuild $(XFLAGS) -scheme tsync clean
	xcodebuild $(XFLAGS) -scheme TsyncTests clean
