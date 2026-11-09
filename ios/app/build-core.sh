#!/bin/zsh
# Builds the core's object for the iOS device and the simulator into core/, on
# a Mac with the opam switches ios-device (iPhoneOS) and ios-cross (simulator).
set -eu
cd "${0:A:h}/../.."
export PATH=/opt/homebrew/bin:$PATH VER=16.0
for pair in iphoneos:ios-device iphonesimulator:ios-cross; do
  sdk=${pair%%:*} switch=${pair##*:}
  print "$(date +%T) core for $sdk (switch $switch)"
  eval "$(opam env --switch=$switch --set-switch)"
  build=$PWD/ios/app/_build-$sdk log=$PWD/ios/app/_build-$sdk.log
  if ! dune build --build-dir=$build -x ios @ios/core/all > $log 2>&1; then
    grep -v "warning: object file .* was built for newer iOS" $log
    exit 1
  fi
  mkdir -p ios/app/core/$sdk
  cp -f $build/default.ios/ios/core/libtsyncios.exe.o ios/app/core/$sdk/libtsyncios.o
done
print "$(date +%T) done"
