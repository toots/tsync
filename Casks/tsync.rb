# The nightly release replaces tsync.pkg at one URL, so there is no version or
# checksum to pin. The installer checks the package's Developer ID signature
# and notarization instead.
cask "tsync" do
  version :latest
  sha256 :no_check

  url "https://github.com/toots/tsync/releases/download/nightly/tsync.pkg"
  name "tsync"
  desc "Folder backed by storage you control, downloading files on open"
  homepage "https://github.com/toots/tsync"

  depends_on arch: :arm64
  depends_on macos: :ventura

  pkg "tsync.pkg"

  # Runs on upgrade as well, so it leaves the domains and local data alone:
  # `tsync fileprovider purge` removes those. The package's postinstall
  # registers the service again and relaunches the app.
  uninstall launchctl: "org.feverdreamtv.tsync.daemon",
            quit:      "org.feverdreamtv.tsync",
            pkgutil:   "org.feverdreamtv.tsync",
            delete:    "/usr/local/bin/tsync"
end
