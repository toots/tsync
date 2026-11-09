#!/bin/zsh
# Builds the app in Release, signs it with the Xcode account's team and installs
# it on the one iPhone connected to this Mac. Run on the Mac, after ./build-core.sh.
set -u
log() { print "$(date +%T) $*" | tee -a /tmp/tsync-ios-device.log }
cd "${0:A:h}"
export PATH=/opt/homebrew/bin:$PATH

# devicectl installs by its own identifier; xcodebuild names a device by its UDID.
xcrun devicectl list devices --json-output /tmp/tsync-devices.json > /dev/null 2>&1
read device udid < <(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("deviceType") == "iPhone" \
       and d["connectionProperties"].get("tunnelState") == "connected":
        print(d["identifier"], d["hardwareProperties"]["udid"]); break
' /tmp/tsync-devices.json)
if [[ -z ${udid:-} ]]; then
  log "no connected iPhone found (xcrun devicectl list devices)"
  exit 1
fi

log "generating the Xcode project"
xcodegen generate > /tmp/tsync-xcodegen.log 2>&1 || { cat /tmp/tsync-xcodegen.log; exit 1 }
log "building Release for $udid (registering it with the team if needed)"
if ! xcodebuild -project TsyncPhone.xcodeproj -scheme TsyncPhone -configuration Release \
    -destination "id=$udid" -derivedDataPath ~/sources/tsync-ios-dd \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    TSYNC_COMMIT=$(git rev-parse --short=12 HEAD) \
    build > /tmp/tsync-xcodebuild.log 2>&1; then
  grep -E "error:" /tmp/tsync-xcodebuild.log | sort -u
  log "build failed; full log in /tmp/tsync-xcodebuild.log"
  exit 1
fi
app=~/sources/tsync-ios-dd/Build/Products/Release-iphoneos/tsync.app
log "installing on $device"
if ! xcrun devicectl device install app --device $device $app >> /tmp/tsync-ios-device.log 2>&1; then
  grep -E "ERROR|Recovery" /tmp/tsync-ios-device.log | tail -2
  log "install failed; full log in /tmp/tsync-ios-device.log"
  exit 1
fi
log "done: open tsync, add the local test domain or join, enable tsync in Files (Browse, ..., Edit), then Run self-test"
