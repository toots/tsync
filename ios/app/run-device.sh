#!/bin/zsh
# Builds the app in Release, signs it with the Xcode account's team and installs
# it on the one iPhone connected to this Mac. Run on the Mac, after ./build-core.sh.
set -u
log() { print "$(date +%T) $*" | tee -a /tmp/tsync-ios-device.log }
cd "${0:A:h}"
export PATH=/opt/homebrew/bin:$PATH
log "generating the Xcode project"
xcodegen generate > /tmp/tsync-xcodegen.log 2>&1 || { cat /tmp/tsync-xcodegen.log; exit 1 }
log "building Release for iOS (signing with automatic provisioning)"
if ! xcodebuild -project TsyncPhone.xcodeproj -scheme TsyncPhone -configuration Release \
    -sdk iphoneos -destination "generic/platform=iOS" -derivedDataPath ~/sources/tsync-ios-dd \
    -allowProvisioningUpdates build > /tmp/tsync-xcodebuild.log 2>&1; then
  grep -E "error:" /tmp/tsync-xcodebuild.log | sort -u
  log "build failed; full log in /tmp/tsync-xcodebuild.log"
  exit 1
fi
app=~/sources/tsync-ios-dd/Build/Products/Release-iphoneos/tsync.app
device=$(xcrun devicectl list devices 2>/dev/null | grep -E 'iPhone.*connected' \
  | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)
if [[ -z $device ]]; then
  log "built $app; no connected iPhone found (xcrun devicectl list devices)"
  exit 1
fi
log "installing on $device"
xcrun devicectl device install app --device $device $app | tee -a /tmp/tsync-ios-device.log
log "done: open tsync, add the local test domain or join, enable tsync in Files (Browse, ..., Edit), then Run self-test"
