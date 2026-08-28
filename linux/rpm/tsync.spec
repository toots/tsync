# Packages the binary linux/build.sh already made, so rpmbuild never has to
# drive opam: no %prep, no %build, no Source0. linux/rpm/build.sh passes srcdir.
#
# rpm generates Requires from the ELF on its own, so there is no hand-kept
# library list to go stale. fuse3 is the exception — fusermount3 is an exec,
# not a link, so nothing in the binary points at it.

# The binary is stripped in %%install; without this rpmbuild tries to extract
# debuginfo from it and fails on an OCaml executable.
%global debug_package %{nil}

Name:           tsync
Version:        0.0.0
Release:        %{?build_release}%{!?build_release:0}%{?dist}
Summary:        Cloud-backed filesystem sync tool
License:        MIT
URL:            https://github.com/toots/tsync

Requires:       fuse3
BuildRequires:  systemd-rpm-macros

%description
Mounts a cloud bucket as a local filesystem, storing files as
content-addressed chunks so edits and duplicates upload once.

# A subpackage, not part of tsync: the tray pulls libdbus and is useless without
# a desktop session, and a headless server installing tsync should get neither.
# Pinned to the exact build it ships beside -- the two speak over the IPC socket,
# and a mismatched pair is not something to discover at runtime.
%package tray
Summary:        System-tray status icon for tsync
Requires:       %{name} = %{version}-%{release}

%description tray
Shows what each tsync domain is doing in the desktop notification area, with a
menu listing the files in flight and a switch that pauses uploads.

# Split off for the reason the tray is: this one links Qt and KDE Frameworks,
# which a GNOME desktop installing the tray should not be made to carry.
%package dolphin
Summary:        Copy a tsync share link from Dolphin
Requires:       %{name} = %{version}-%{release}

%description dolphin
Adds a Copy Share Link entry to the context menu of a file or folder inside a
tsync mount, which publishes a public download URL and puts it on the clipboard.

%install
install -Dm755 %{srcdir}/_build/default/bin/tsync.exe %{buildroot}%{_bindir}/tsync
strip %{buildroot}%{_bindir}/tsync
install -Dm755 %{srcdir}/_build/default/linux/tray/main.exe %{buildroot}%{_bindir}/tsync-tray
strip %{buildroot}%{_bindir}/tsync-tray
install -Dm644 %{srcdir}/linux/tsync@.service %{buildroot}%{_unitdir}/tsync@.service
install -d %{buildroot}%{_sysconfdir}/xdg/autostart
sed 's|@BIN@|%{_bindir}/tsync-tray|' %{srcdir}/linux/tsync-tray.desktop.in \
  > %{buildroot}%{_sysconfdir}/xdg/autostart/tsync-tray.desktop
# The application icon goes to the base package: both desktop packages want it
# and a file has one owner. The four tray states are the tray's alone, and their
# suffix and the symbolic/ directory are a pair -- together they are what makes
# GTK recolour to the panel foreground. Qt ignores both and recolours by the
# stylesheet the SVGs carry instead.
install -Dm644 %{srcdir}/assets/tsync-app.svg \
  %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/tsync.svg
for state in idle sync paused error; do
  install -Dm644 %{srcdir}/assets/tray/tsync-$state-symbolic.svg \
    %{buildroot}%{_datadir}/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg
done
# Installed by cmake rather than copied out of its build directory: a plugin
# copied from there keeps the rpath it was built with, which names a path on the
# build machine. Only the install step rewrites that to where the mount rules
# actually land. The two components ship in different packages.
DESTDIR=%{buildroot} cmake --install %{srcdir}/linux/dolphin/build \
  --component plugin
DESTDIR=%{buildroot} cmake --install %{srcdir}/linux/dolphin/build \
  --component rules
strip %{buildroot}%{_libdir}/qt6/plugins/kf6/kfileitemaction/tsyncdolphin.so
strip %{buildroot}%{_libdir}/tsync/libtsync_mounts.so

%files
%{_bindir}/tsync
%{_unitdir}/tsync@.service
%{_datadir}/icons/hicolor/scalable/apps/tsync.svg
%{_libdir}/tsync/libtsync_mounts.so

%files tray
%{_bindir}/tsync-tray
%{_sysconfdir}/xdg/autostart/tsync-tray.desktop
%{_datadir}/icons/hicolor/symbolic/apps/tsync-*-symbolic.svg

%files dolphin
%{_libdir}/qt6/plugins/kf6/kfileitemaction/tsyncdolphin.so

# The unit is a template with no default instance, so these only refresh
# already-enabled tsync@<user> instances across an upgrade.
%post
%systemd_post tsync@.service

%preun
%systemd_preun tsync@.service

%postun
%systemd_postun_with_restart tsync@.service
