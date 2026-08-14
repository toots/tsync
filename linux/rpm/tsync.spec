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

%install
install -Dm755 %{srcdir}/_build/default/bin/tsync.exe %{buildroot}%{_bindir}/tsync
strip %{buildroot}%{_bindir}/tsync
install -Dm755 %{srcdir}/_build/default/tray/main.exe %{buildroot}%{_bindir}/tsync-tray
strip %{buildroot}%{_bindir}/tsync-tray
install -Dm644 %{srcdir}/linux/tsync@.service %{buildroot}%{_unitdir}/tsync@.service
install -d %{buildroot}%{_sysconfdir}/xdg/autostart
sed 's|@BIN@|%{_bindir}/tsync-tray|' %{srcdir}/linux/tsync-tray.desktop.in \
  > %{buildroot}%{_sysconfdir}/xdg/autostart/tsync-tray.desktop
# The .desktop names an icon and the tray asks for four more, so the package
# that ships them is the package that has to ship the icons. The suffix and the
# symbolic/ directory are a pair: together they are what makes GTK recolour to
# the panel foreground. Qt ignores both and recolours by the stylesheet the
# SVGs carry instead.
install -Dm644 %{srcdir}/assets/tsync-app.svg \
  %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/tsync.svg
for state in idle sync paused error; do
  install -Dm644 %{srcdir}/assets/tray/tsync-$state-symbolic.svg \
    %{buildroot}%{_datadir}/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg
done

%files
%{_bindir}/tsync
%{_unitdir}/tsync@.service

%files tray
%{_bindir}/tsync-tray
%{_sysconfdir}/xdg/autostart/tsync-tray.desktop
%{_datadir}/icons/hicolor/scalable/apps/tsync.svg
%{_datadir}/icons/hicolor/symbolic/apps/tsync-*-symbolic.svg

# The unit is a template with no default instance, so these only refresh
# already-enabled tsync@<user> instances across an upgrade.
%post
%systemd_post tsync@.service

%preun
%systemd_preun tsync@.service

%postun
%systemd_postun_with_restart tsync@.service
