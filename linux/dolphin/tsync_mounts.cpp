#include "tsync_mounts.h"

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

QList<TsyncMount> tsyncMounts()
{
    static bool started = false;
    if (!started) {
        // No argv of our own inside a plugin, and none is read: the name is
        // what the runtime reports about itself.
        char program[] = "tsyncdolphin";
        char *argv[] = {program, nullptr};
        caml_startup(argv);
        started = true;
    }

    static const value *answer = nullptr;
    if (!answer) {
        answer = caml_named_value("tsync_mount_points");
    }
    QList<TsyncMount> mounts;
    if (!answer) {
        return mounts;
    }

    // Copied out as it is walked. Nothing here allocates on the OCaml heap, so
    // the list cannot move underneath the loop.
    value list = caml_callback(*answer, Val_unit);
    while (Is_block(list)) {
        const value pair = Field(list, 0);
        mounts.append(TsyncMount{QString::fromUtf8(String_val(Field(pair, 0))),
                                 QString::fromUtf8(String_val(Field(pair, 1)))});
        list = Field(list, 1);
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
