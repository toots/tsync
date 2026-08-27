// What the plugin decides before Dolphin draws anything: which reply names a
// mount, and which mount holds the file that was clicked.

#include "tsync_mounts.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTextStream>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

int checks = 0;
int failures = 0;

void check(bool ok, const QString &what)
{
    ++checks;
    QTextStream out(stdout);
    if (ok) {
        out << "  ok   " << what << "\n";
    } else {
        ++failures;
        out << "  FAIL " << what << "\n";
    }
}

QByteArray status(const char *json)
{
    return QByteArray(json);
}

// A real one, because the entry types a directory listing is normally asked for
// leave a socket out and no canned fixture would show it.
bool bindSocket(const QString &path)
{
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    const QByteArray raw = path.toLocal8Bit();
    if (raw.size() >= static_cast<int>(sizeof(addr.sun_path))) {
        ::close(fd);
        return false;
    }
    ::memcpy(addr.sun_path, raw.constData(), raw.size());
    const bool ok = ::bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0;
    ::close(fd);
    return ok;
}

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    TsyncMount parsed;
    check(tsyncMountFromStatus(
              status(R"({"ok":true,"domain":"Files","mount":"/mnt/files"})"),
              QStringLiteral("/run/s.sock"), &parsed)
              && parsed.mount == QStringLiteral("/mnt/files")
              && parsed.domain == QStringLiteral("Files")
              && parsed.socket == QStringLiteral("/run/s.sock"),
          QStringLiteral("a status naming a mount is taken"));

    check(tsyncMountFromStatus(status(R"({"ok":true,"mount":"/mnt/files/"})"),
                               QString(), &parsed)
              && parsed.mount == QStringLiteral("/mnt/files"),
          QStringLiteral("a trailing slash on the mount is dropped"));

    check(!tsyncMountFromStatus(status(R"({"ok":true,"running":true})"),
                                QString(), &parsed),
          QStringLiteral("a service that mounts nothing is left out"));

    check(!tsyncMountFromStatus(QByteArray(), QString(), &parsed),
          QStringLiteral("a socket nothing listens on is left out"));

    check(!tsyncMountFromStatus(status("not json at all"), QString(), &parsed),
          QStringLiteral("anything else in the directory is left out"));

    const QList<TsyncMount> mounts = {
        TsyncMount{QStringLiteral("/run/a.sock"), QStringLiteral("Files"),
                   QStringLiteral("/mnt/files")},
        TsyncMount{QStringLiteral("/run/b.sock"), QStringLiteral("Media"),
                   QStringLiteral("/mnt/files/media")},
    };

    TsyncMount found;
    QString rel;
    check(tsyncResolve(mounts, QStringLiteral("/mnt/files/a/b.txt"), &found, &rel)
              && found.domain == QStringLiteral("Files")
              && rel == QStringLiteral("a/b.txt"),
          QStringLiteral("a file under a mount resolves to its relative path"));

    check(tsyncResolve(mounts, QStringLiteral("/mnt/files"), &found, &rel)
              && rel.isEmpty(),
          QStringLiteral("the mount itself names the whole domain"));

    check(tsyncResolve(mounts, QStringLiteral("/mnt/files/media/x.mkv"), &found,
                       &rel)
              && found.domain == QStringLiteral("Media")
              && rel == QStringLiteral("x.mkv"),
          QStringLiteral("a mount inside another wins over it"));

    check(!tsyncResolve(mounts, QStringLiteral("/mnt/files-elsewhere/x"), &found,
                        &rel),
          QStringLiteral("a sibling sharing the mount's prefix is not under it"));

    check(!tsyncResolve(mounts, QStringLiteral("/home/someone/x"), &found, &rel),
          QStringLiteral("a path under no mount resolves to nothing"));

    check(!tsyncResolve({}, QStringLiteral("/mnt/files/a"), &found, &rel),
          QStringLiteral("with no daemon answering, nothing resolves"));

    QTemporaryDir dataDir;
    check(dataDir.isValid(), QStringLiteral("the staging directory is there"));
    const QString socketPath = dataDir.filePath(QStringLiteral("tsync-real.sock"));
    check(bindSocket(socketPath), QStringLiteral("a socket can be staged"));
    QFile plain(dataDir.filePath(QStringLiteral("tsync-Files.sock.bak")));
    plain.open(QIODevice::WriteOnly);
    plain.close();

    const QStringList listed = tsyncSocketPaths(dataDir.path());
    check(listed == QStringList{socketPath},
          QStringLiteral("a daemon's socket is listed and nothing else is"));
    check(tsyncMounts(dataDir.path()).isEmpty(),
          QStringLiteral("a socket that never answers yields no mount"));

    QTextStream out(stdout);
    out << "\n" << (checks - failures) << "/" << checks << " checks passed\n";
    // A suite that asserted nothing has not passed.
    return failures == 0 && checks > 0 ? 0 : 1;
}
