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

%install
install -Dm755 %{srcdir}/_build/default/bin/tsync.exe %{buildroot}%{_bindir}/tsync
strip %{buildroot}%{_bindir}/tsync
install -Dm644 %{srcdir}/linux/tsync@.service %{buildroot}%{_unitdir}/tsync@.service

%files
%{_bindir}/tsync
%{_unitdir}/tsync@.service

# The unit is a template with no default instance, so these only refresh
# already-enabled tsync@<user> instances across an upgrade.
%post
%systemd_post tsync@.service

%preun
%systemd_preun tsync@.service

%postun
%systemd_postun_with_restart tsync@.service
