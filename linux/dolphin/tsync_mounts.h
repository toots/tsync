#pragma once

#include <QList>
#include <QString>
#include <QStringList>

// A tsync daemon answering on this machine, and where it says it mounted.
struct TsyncMount {
    QString socket;
    QString domain;
    QString mount;
};

// Where the daemons put their sockets, by the same XDG rule linux_runtime.ml
// follows.
QString tsyncDataDir();

// The mount a status reply names, if it names one. A reply from a service that
// mounts nothing, from a socket nothing is listening on, or from something else
// entirely, all answer false rather than a mount of "".
bool tsyncMountFromStatus(const QByteArray &reply, const QString &socketPath,
                          TsyncMount *out);

// Every socket in [dataDir] that could be a daemon's. QDir::System is what puts
// a unix socket in the listing at all: the entry types a caller normally asks
// for cover regular files and directories, and a socket is neither.
QStringList tsyncSocketPaths(const QString &dataDir);

// Every daemon under [dataDir] that answers a status naming a mount.
QList<TsyncMount> tsyncMounts(const QString &dataDir);

// The mount holding [path], and the domain-relative path within it -- empty for
// the mount itself, which names the whole domain.
bool tsyncResolve(const QList<TsyncMount> &mounts, const QString &path,
                  TsyncMount *found, QString *rel);
