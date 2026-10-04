// Which mount holds a path (spec frontends/dolphin.md §2 step 3). Paths are
// bytes: nothing here assumes an encoding.
#pragma once

#include <QByteArray>
#include <QList>
#include <QString>

namespace tsync {

struct Mount {
    QByteArray mountPoint;
    QByteArray socket;
};

struct Resolved {
    bool found = false;
    Mount mount;
    QByteArray rel;
    QString displayName;
};

/// The one filesystem question resolution asks, so that a test can prove it
/// is never asked at or below a mount point.
class LinkReader
{
public:
    virtual ~LinkReader() = default;
    /// The target of the symbolic link at this path; false when it is not one.
    virtual bool readLink(const QByteArray &path, QByteArray *target) = 0;
};

class SystemLinkReader : public LinkReader
{
public:
    bool readLink(const QByteArray &path, QByteArray *target) override;
};

/// No `.` or `..` segment, no repeated or trailing `/`.
QByteArray normalise(const QByteArray &path);

Resolved resolve(const QByteArray &path, const QList<Mount> &mounts, LinkReader &links);

}
