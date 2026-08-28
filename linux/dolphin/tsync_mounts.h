#pragma once

#include <QList>
#include <QString>

// A tsync filesystem mounted on this machine, and where its daemon listens.
struct TsyncMount {
    QString mount;
    QString socket;
};

// Every tsync filesystem mounted right now. Answered by tsync itself rather
// than worked out here: where a domain mounts and where its daemon listens are
// its rules, and a copy of them here would drift.
//
// Starts the OCaml runtime on first use, so it must be called from one thread
// only -- the one drawing the menu.
QList<TsyncMount> tsyncMounts();

// The mount holding [path], and the domain-relative path within it -- empty for
// the mount itself, which names the whole domain.
bool tsyncResolve(const QList<TsyncMount> &mounts, const QString &path,
                  TsyncMount *found, QString *rel);
