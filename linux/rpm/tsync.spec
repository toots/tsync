# Packages what linux/build.sh already made, so rpmbuild never drives
# opam: no %prep, no %build, no Source0. linux/rpm/build.sh passes srcdir.
#
# rpm generates Requires from the ELF; fuse3 is the exception, since
# fusermount3 is executed, not linked.

# Stripped in %%install: rpmbuild would otherwise try to extract debuginfo from
# an OCaml executable, and fail.
%global debug_package %{nil}

Name:           tsync
Version:        0.0.0
Release:        %{?build_release}%{!?build_release:0}%{?dist}
Summary:        Synchronise folders through object stores
License:        MIT
URL:            https://github.com/toots/tsync

Requires:       fuse3
BuildRequires:  systemd-rpm-macros

%description
Keeps folders in step across machines through cloud buckets or a peer,
storing files as content-addressed chunks so edits and duplicates upload
once, and mounts them with FUSE.

# linux-desktop §5.1: the tray and the plugin are apart so that a headless
# machine carries no bus or toolkit library, and each is pinned to the build
# beside it because both speak the owner's request interface.
%package tray
Summary:        Tray icon for tsync
Requires:       tsync = %{version}-%{release}

%description tray
Shows the state of every tsync domain as an icon in the desktop's
notification area, with a menu to open folders and hold changes.

%package dolphin
Summary:        Dolphin context menu for tsync
Requires:       tsync = %{version}-%{release}

%description dolphin
Adds share links and offline availability to the context menu of files and
folders in a tsync mount.

# The discovery library sits outside the loader's default path, so rpm gives
# it no Provides; the plugin's need of it is the exact version above.
%global __requires_exclude ^libtsync_mounts\\.so.*$

%install
install -Dm755 %{srcdir}/_build/default/bin/tsync.exe %{buildroot}%{_bindir}/tsync
strip %{buildroot}%{_bindir}/tsync
install -Dm644 %{srcdir}/linux/tsync@.service %{buildroot}%{_unitdir}/tsync@.service
install -Dm644 %{srcdir}/assets/tsync-app.svg \
  %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/tsync.svg
install -Dm755 %{srcdir}/_build/default/linux/mounts/libtsync_mounts.so \
  %{buildroot}%{_libdir}/tsync/libtsync_mounts.so
strip --strip-unneeded %{buildroot}%{_libdir}/tsync/libtsync_mounts.so
install -Dm755 %{srcdir}/_build/default/linux/tray/tsync_tray.exe %{buildroot}%{_bindir}/tsync-tray
strip %{buildroot}%{_bindir}/tsync-tray
install -Dm644 %{srcdir}/linux/tsync-tray.desktop \
  %{buildroot}%{_sysconfdir}/xdg/autostart/tsync-tray.desktop
for state in idle sync paused error; do
  install -Dm644 %{srcdir}/assets/tray/tsync-$state-symbolic.svg \
    %{buildroot}%{_datadir}/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg
done
DESTDIR=%{buildroot} cmake --install %{srcdir}/linux/dolphin/build --strip

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

# The unit is a template with no default instance, so the systemd macros reach
# only the unit file: a running tsync@<user> is not a unit the template's name
# reaches. The instances are enumerated here, as the deb's scripts do.
%post
%systemd_post tsync@.service
if [ $1 -ge 2 ] && [ -d /run/systemd/system ]; then
    units=$(systemctl list-units --full --plain --no-legend --state=active \
        'tsync@*.service' 2>/dev/null | cut -d' ' -f1)
    [ -z "$units" ] || systemctl try-restart $units >/dev/null 2>&1 || :
fi

# Stopped while the binary is still on disk, so `tsync stop` can unmount.
%preun
if [ $1 -eq 0 ] && [ -d /run/systemd/system ]; then
    units=$(systemctl list-units --full --plain --no-legend --state=active \
        'tsync@*.service' 2>/dev/null | cut -d' ' -f1)
    [ -z "$units" ] || systemctl stop $units >/dev/null 2>&1 || :
fi
%systemd_preun tsync@.service

%postun
%systemd_postun tsync@.service
