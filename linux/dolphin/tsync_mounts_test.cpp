// What the plugin decides before Dolphin draws anything: what comes back across
// the OCaml boundary, and which mount holds the file that was clicked.
//
// Linked against the fake object, so the answers are fixed here rather than
// whatever this machine happens to have mounted.

#include "tsync_mounts.h"

#include <QCoreApplication>
#include <QTextStream>

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

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    const QList<TsyncMount> mounts = tsyncMounts();
    check(mounts.size() == 3, QStringLiteral("every mount crosses the boundary"));
    check(mounts.size() > 0 && mounts.at(0).mount == QStringLiteral("/mnt/files")
              && mounts.at(0).socket
                     == QStringLiteral("/run/tsync-Files.sock"),
          QStringLiteral("both halves of a pair arrive intact"));
    check(mounts.size() > 2
              && mounts.at(2).mount == QStringLiteral("/mnt/spaced name"),
          QStringLiteral("a mount point with a space survives the crossing"));
    check(tsyncMounts().size() == mounts.size(),
          QStringLiteral("asking twice starts the runtime once and answers the "
                         "same"));

    TsyncMount found;
    QString rel;
    check(tsyncResolve(mounts, QStringLiteral("/mnt/files/a/b.txt"), &found, &rel)
              && found.socket == QStringLiteral("/run/tsync-Files.sock")
              && rel == QStringLiteral("a/b.txt"),
          QStringLiteral("a file under a mount resolves to its relative path"));

    check(tsyncResolve(mounts, QStringLiteral("/mnt/files"), &found, &rel)
              && rel.isEmpty(),
          QStringLiteral("the mount itself names the whole domain"));

    check(tsyncResolve(mounts, QStringLiteral("/mnt/files/media/x.mkv"), &found,
                       &rel)
              && found.socket == QStringLiteral("/run/tsync-Media.sock")
              && rel == QStringLiteral("x.mkv"),
          QStringLiteral("a mount inside another wins over it"));

    check(!tsyncResolve(mounts, QStringLiteral("/mnt/files-elsewhere/x"), &found,
                        &rel),
          QStringLiteral("a sibling sharing the mount's prefix is not under it"));

    check(!tsyncResolve(mounts, QStringLiteral("/home/someone/x"), &found, &rel),
          QStringLiteral("a path under no mount resolves to nothing"));

    check(!tsyncResolve({}, QStringLiteral("/mnt/files/a"), &found, &rel),
          QStringLiteral("with nothing mounted, nothing resolves"));

    QTextStream out(stdout);
    out << "\n" << (checks - failures) << "/" << checks << " checks passed\n";
    // A suite that asserted nothing has not passed.
    return failures == 0 && checks > 0 ? 0 : 1;
}
