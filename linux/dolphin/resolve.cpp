#include "resolve.h"

#include <limits.h>
#include <unistd.h>

namespace tsync {

static const int maxLinks = 40;

bool SystemLinkReader::readLink(const QByteArray &path, QByteArray *target)
{
    char buffer[PATH_MAX];
    const ssize_t length = ::readlink(path.constData(), buffer, sizeof buffer);
    if (length < 0)
        return false;
    *target = QByteArray(buffer, int(length));
    return true;
}

static QList<QByteArray> segments(const QByteArray &path)
{
    QList<QByteArray> kept;
    for (const QByteArray &segment : path.split('/')) {
        if (segment.isEmpty() || segment == ".")
            continue;
        if (segment == "..") {
            if (!kept.isEmpty())
                kept.removeLast();
        } else {
            kept.append(segment);
        }
    }
    return kept;
}

static QByteArray joined(const QList<QByteArray> &parts)
{
    return "/" + parts.join('/');
}

QByteArray normalise(const QByteArray &path)
{
    return joined(segments(path));
}

static bool holds(const QByteArray &mountPoint, const QByteArray &path)
{
    return path == mountPoint || path.startsWith(mountPoint == "/" ? mountPoint : mountPoint + '/');
}

static const Mount *holder(const QByteArray &path, const QList<Mount> &mounts)
{
    const Mount *longest = nullptr;
    for (const Mount &mount : mounts)
        if (holds(mount.mountPoint, path) && (!longest || mount.mountPoint.size() > longest->mountPoint.size()))
            longest = &mount;
    return longest;
}

static bool isMountPoint(const QByteArray &path, const QList<Mount> &mounts)
{
    for (const Mount &mount : mounts)
        if (mount.mountPoint == path)
            return true;
    return false;
}

// Resolves links one component at a time from the root and stops at the
// first prefix that is a mount point, before asking anything about it.
static QByteArray throughLinks(const QByteArray &path, const QList<Mount> &mounts, LinkReader &links)
{
    QList<QByteArray> rest = segments(path);
    QList<QByteArray> resolved;
    int followed = 0;
    while (!rest.isEmpty()) {
        resolved.append(rest.takeFirst());
        const QByteArray prefix = joined(resolved);
        if (isMountPoint(prefix, mounts))
            return rest.isEmpty() ? prefix : prefix + '/' + rest.join('/');
        QByteArray target;
        if (!links.readLink(prefix, &target))
            continue;
        if (++followed > maxLinks)
            return QByteArray();
        resolved.removeLast();
        const QByteArray base = target.startsWith('/') ? QByteArray() : joined(resolved);
        rest = segments(base + '/' + target + '/' + rest.join('/'));
        resolved.clear();
    }
    return QByteArray();
}

Resolved resolve(const QByteArray &path, const QList<Mount> &mounts, LinkReader &links)
{
    Resolved result;
    if (mounts.isEmpty())
        return result;
    QByteArray candidate = normalise(path);
    const Mount *mount = holder(candidate, mounts);
    if (!mount) {
        candidate = throughLinks(candidate, mounts, links);
        mount = candidate.isEmpty() ? nullptr : holder(candidate, mounts);
    }
    if (!mount)
        return result;
    result.found = true;
    result.mount = *mount;
    if (candidate != mount->mountPoint)
        result.rel = candidate.mid(mount->mountPoint == "/" ? 1 : mount->mountPoint.size() + 1);
    result.displayName = result.rel.isEmpty()
        ? QStringLiteral("The folder")
        : QString::fromUtf8(result.rel.mid(result.rel.lastIndexOf('/') + 1));
    return result;
}

}
