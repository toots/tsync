#include "menu.h"

#include <QDateTime>
#include <QLocale>

namespace tsync {

static MenuAction share()
{
    return {ActionKind::Share, QStringLiteral("Copy Share Link"), QStringLiteral("tsync")};
}

static MenuAction restore(const QString &label)
{
    return {ActionKind::Restore, label, QStringLiteral("cloud-download")};
}

static MenuAction evict()
{
    return {ActionKind::Evict, QStringLiteral("Make Online Only"), QStringLiteral("cloud-upload")};
}

QList<MenuAction> actionsFor(const ItemState &state)
{
    const QString offline = QStringLiteral("Make Available Offline");
    switch (state.outcome) {
    case ItemState::NotFound:
        return {};
    case ItemState::Unknown:
        return {share()};
    case ItemState::Row:
        break;
    }
    if (state.kind == QLatin1String("dir"))
        return {share(), restore(offline), evict()};
    if (state.kind != QLatin1String("file"))
        return {share()};
    if (state.availability == QLatin1String("pinned"))
        return {share(), restore(QStringLiteral("Keep Offline Longer")), evict()};
    if (state.availability == QLatin1String("cached"))
        return {share(), restore(offline), evict()};
    if (state.availability == QLatin1String("online-only"))
        return {share(), restore(offline)};
    return {share()};
}

QString actionName(ActionKind kind)
{
    switch (kind) {
    case ActionKind::Share:
        return QStringLiteral("share");
    case ActionKind::Restore:
        return QStringLiteral("restore");
    case ActionKind::Evict:
        return QStringLiteral("evict");
    }
    return QString();
}

bool isBulk(ActionKind kind, bool directory)
{
    return kind == ActionKind::Restore || (kind == ActionKind::Evict && directory);
}

QString startNotice(ActionKind kind, bool directory, const QString &name)
{
    if (!directory)
        return QString();
    switch (kind) {
    case ActionKind::Restore:
        return QStringLiteral("Making %1 available offline…").arg(name);
    case ActionKind::Evict:
        return QStringLiteral("Making %1 online only…").arg(name);
    case ActionKind::Share:
        break;
    }
    return QString();
}

static QString counted(const QString &name, const QJsonObject &reply, const char *done, const QString &sentence, const QString &failure)
{
    const qint64 failed = reply.value(QLatin1String("failed")).toInteger();
    QString text = QStringLiteral("%1: %2 %3").arg(name).arg(reply.value(QLatin1String(done)).toInteger()).arg(sentence);
    if (failed > 0)
        text += QStringLiteral(" %1 %2").arg(failed).arg(failure);
    return text;
}

QString successNotice(ActionKind kind, bool directory, const QString &name, const QJsonObject &reply)
{
    switch (kind) {
    case ActionKind::Share: {
        const QDate date = QDateTime::fromSecsSinceEpoch(qint64(reply.value(QLatin1String("expires")).toDouble())).date();
        return QStringLiteral("Share link copied to the clipboard. It expires on %1.").arg(QLocale().toString(date, QLocale::ShortFormat));
    }
    case ActionKind::Restore:
        return directory
            ? counted(name, reply, "restored", QStringLiteral("files available offline."), QStringLiteral("could not be fetched."))
            : QStringLiteral("%1 is available offline.").arg(name);
    case ActionKind::Evict:
        return directory
            ? counted(name, reply, "evicted", QStringLiteral("files are online only."), QStringLiteral("could not be released."))
            : QStringLiteral("%1 is online only.").arg(name);
    }
    return QString();
}

QString refusalNotice(const QString &error)
{
    return error.isEmpty() ? QStringLiteral("The daemon refused.") : error;
}

QString noAnswerNotice(ActionKind kind, bool directory, const QString &name)
{
    return isBulk(kind, directory)
        ? QStringLiteral("The tsync daemon stopped answering. The change to %1 may still complete.").arg(name)
        : QStringLiteral("The tsync daemon did not answer.");
}

}
