#!/bin/sh
# Assembles the apt and dnf repositories out of the packages in $1, into the
# site directory $2. Run from the repo root.
#
# Nothing here is incremental: the site is rebuilt from the packages every time,
# so it serves exactly what the nightly release holds and a stale index has
# nowhere to survive.
#
# Needs dpkg-dev, apt-utils, createrepo-c and a gpg secret key.
set -eu

pkgs=$(cd "${1:-dist}" && pwd)
site=${2:-site}
base=${REPO_BASE_URL:-https://toots.github.io/tsync}

# Signing is not optional: apt refuses an unsigned repository outright, so a
# missing key has to stop the publish rather than ship something every client
# rejects at its first update.
gpg --list-secret-keys --with-colons | grep -q '^sec:' \
  || { echo "no gpg secret key; see scripts/setup_repo_signing.sh" >&2; exit 1; }

rm -rf "$site"
mkdir -p "$site"
gpg --export --armor > "$site/tsync.asc"

# The distro a package was built for is the middle field of its name --
# tsync-tray_deb13_amd64.deb -- and a package name carries no underscore, so the
# split is unambiguous. Both architectures land in one directory: apt and dnf
# each pick the entry matching the machine out of a single index.
sort_by_distro() {
  for f in "$pkgs"/*."$1"; do
    test -e "$f" || { echo "no .$1 in $pkgs" >&2; exit 1; }
    d="$site/$1/$(basename "$f" | cut -d_ -f2)"
    mkdir -p "$d"
    cp "$f" "$d/"
  done
}

sort_by_distro deb
sort_by_distro rpm

for d in "$site"/deb/*/; do
  (
    cd "$d"
    dpkg-scanpackages --multiversion . > Packages
    gzip -9kf Packages
    apt-ftparchive -o APT::FTPArchive::Release::Origin=tsync release . > Release
    # InRelease only, and Release goes with it: leaving an unsigned Release
    # behind gives apt a second thing to fetch that nothing vouches for.
    gpg --batch --yes --clearsign -o InRelease Release
    rm Release
  )
  cat > "$d/tsync.sources" <<EOF
Types: deb
URIs: $base/deb/$(basename "$d")
Suites: ./
Signed-By: /etc/apt/keyrings/tsync.asc
EOF
done

for d in "$site"/rpm/*/; do
  createrepo_c --quiet "$d"
  gpg --batch --yes --detach-sign --armor "$d/repodata/repomd.xml"
  # repo_gpgcheck alone, because the packages themselves carry no signature: the
  # one on repomd.xml covers primary.xml's checksums, which cover every package,
  # so the chain reaches the same place.
  cat > "$d/tsync.repo" <<EOF
[tsync]
name=tsync
baseurl=$base/rpm/$(basename "$d")
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=$base/tsync.asc
EOF
done

cat > "$site/setup.sh" <<EOF
#!/bin/sh
# Adds the tsync package repository:
#   curl -fsSL $base/setup.sh | sudo sh
set -eu

fetch() {
  curl -fsSL "\$1" -o "\$2" && return 0
  echo "nothing published at \$1 -- no tsync packages for \$ID \$VERSION_ID" >&2
  exit 1
}

if [ -d /etc/apt/sources.list.d ]; then
  . /etc/os-release
  case "\$ID" in
    debian) suffix="deb\$VERSION_ID" ;;
    *) suffix="\$ID\$VERSION_ID" ;;
  esac
  install -d /etc/apt/keyrings
  fetch "$base/tsync.asc" /etc/apt/keyrings/tsync.asc
  fetch "$base/deb/\$suffix/tsync.sources" /etc/apt/sources.list.d/tsync.sources
  apt-get update
  echo "done -- apt-get install tsync"
elif [ -d /etc/yum.repos.d ]; then
  . /etc/os-release
  fetch "$base/rpm/fc\$VERSION_ID/tsync.repo" /etc/yum.repos.d/tsync.repo
  echo "done -- dnf install tsync"
else
  echo "neither apt nor dnf here" >&2
  exit 1
fi
EOF
chmod +x "$site/setup.sh"

# Listed from the directories that exist rather than written by hand, so the
# page cannot name a distribution the build did not produce.
{
  printf '<!doctype html><meta charset=utf-8><title>tsync packages</title>'
  printf '<style>body{font:14px/1.6 system-ui,sans-serif;margin:3rem auto;max-width:44rem;padding:0 1rem}'
  printf 'pre{background:#f4f4f4;padding:.8rem;overflow-x:auto}</style>'
  printf '<h1>tsync packages</h1>'
  printf '<p>Rolling builds of <a href="https://github.com/toots/tsync">main</a>.</p>'
  printf '<pre>curl -fsSL %s/setup.sh | sudo sh</pre><h2>By hand</h2>' "$base"
  for d in "$site"/deb/*/; do
    n=$(basename "$d")
    printf '<h3>%s</h3><pre>sudo install -d /etc/apt/keyrings\n' "$n"
    printf 'sudo curl -fsSL %s/tsync.asc -o /etc/apt/keyrings/tsync.asc\n' "$base"
    printf 'sudo curl -fsSL %s/deb/%s/tsync.sources -o /etc/apt/sources.list.d/tsync.sources\n' "$base" "$n"
    printf 'sudo apt-get update &amp;&amp; sudo apt-get install tsync</pre>'
  done
  for d in "$site"/rpm/*/; do
    n=$(basename "$d")
    printf '<h3>%s</h3><pre>sudo curl -fsSL %s/rpm/%s/tsync.repo -o /etc/yum.repos.d/tsync.repo\n' "$n" "$base" "$n"
    printf 'sudo dnf install tsync</pre>'
  done
} > "$site/index.html"

find "$site" -type f | sort
