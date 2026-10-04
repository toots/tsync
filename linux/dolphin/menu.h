// What the context menu offers for an item, and what a click reports (spec
// frontends/dolphin.md §2 step 5, §4). Pure: no socket, no toolkit.
#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

namespace tsync {

enum class ActionKind { Share, Restore, Evict };

struct MenuAction {
    ActionKind kind;
    QString label;
    QString icon;
};

/// What the owner said of the item: its row, that it does not know it, or
/// nothing usable.
struct ItemState {
    enum Outcome { Row, NotFound, Unknown } outcome = Unknown;
    QString kind;
    QString availability;

    bool isDirectory() const { return outcome == Row && kind == QLatin1String("dir"); }
};

QList<MenuAction> actionsFor(const ItemState &state);

/// The request's action name.
QString actionName(ActionKind kind);

/// Restore, and evict of a directory: bounded by the liveness probe, not by a
/// total deadline.
bool isBulk(ActionKind kind, bool directory);

/// Empty when the action has no start notice.
QString startNotice(ActionKind kind, bool directory, const QString &name);

/// The final notice for a successful reply; a share's also needs the link's
/// expiry as a date.
QString successNotice(ActionKind kind, bool directory, const QString &name, const QJsonObject &reply);

QString refusalNotice(const QString &error);
QString noAnswerNotice(ActionKind kind, bool directory, const QString &name);

}
