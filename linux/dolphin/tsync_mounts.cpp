#include "tsync_mounts.h"

#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QStandardPaths>

namespace {

// A menu is built while the user waits, so a daemon that has stopped answering
// costs this much and no more. A local round trip measures well under a
// millisecond.
constexpr int replyTimeoutMs = 150;

QByteArray ask(const QString &socketPath, const QByteArray &request)
{
    QLocalSocket sock;
    sock.connectToServer(socketPath);
    if (!sock.waitForConnected(replyTimeoutMs)) {
        return {};
    }
    sock.write(request);
    sock.write("\n");
    if (!sock.waitForBytesWritten(replyTimeoutMs)) {
        return {};
    }
    QByteArray reply;
    while (!reply.endsWith('\n')) {
        if (!sock.waitForReadyRead(replyTimeoutMs)) {
            return {};
        }
        reply += sock.readAll();
    }
    return reply;
}

}

QString tsyncDataDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QStringLiteral("/tsync");
}

bool tsyncMountFromStatus(const QByteArray &reply, const QString &socketPath,
                          TsyncMount *out)
{
    const QJsonObject obj = QJsonDocument::fromJson(reply).object();
    QString mount = obj.value(QStringLiteral("mount")).toString();
    while (mount.length() > 1 && mount.endsWith(QLatin1Char('/'))) {
        mount.chop(1);
    }
    if (mount.isEmpty()) {
        return false;
    }
    *out = TsyncMount{socketPath, obj.value(QStringLiteral("domain")).toString(),
                      mount};
    return true;
}

// The glob is looser than the daemons' own naming and stays that way: the sync
// service matches it too and answers no mount, a domain removed since leaves a
// socket nothing listens on, and both drop out here without a rule to keep in
// step with linux_runtime.ml.
QStringList tsyncSocketPaths(const QString &dataDir)
{
    const QDir dir(dataDir);
    QStringList paths;
    const QStringList names =
        dir.entryList({QStringLiteral("tsync-*.sock")},
                      QDir::System | QDir::Files | QDir::NoDotAndDotDot);
    for (const QString &name : names) {
        paths.append(dir.absoluteFilePath(name));
    }
    return paths;
}

QList<TsyncMount> tsyncMounts(const QString &dataDir)
{
    QList<TsyncMount> mounts;
    for (const QString &path : tsyncSocketPaths(dataDir)) {
        TsyncMount mount;
        if (tsyncMountFromStatus(ask(path, QByteArrayLiteral("{\"action\":\"status\"}")),
                                 path, &mount)) {
            mounts.append(mount);
        }
    }
    return mounts;
}

// Longest match, since one domain's mount point may sit inside another's.
bool tsyncResolve(const QList<TsyncMount> &mounts, const QString &path,
                  TsyncMount *found, QString *rel)
{
    int best = -1;
    for (int i = 0; i < mounts.size(); ++i) {
        const QString &mount = mounts.at(i).mount;
        if (path != mount && !path.startsWith(mount + QLatin1Char('/'))) {
            continue;
        }
        if (best < 0 || mount.length() > mounts.at(best).mount.length()) {
            best = i;
        }
    }
    if (best < 0) {
        return false;
    }
    *found = mounts.at(best);
    *rel = path == found->mount ? QString()
                                : path.mid(found->mount.length() + 1);
    return true;
}
