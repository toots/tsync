// The Dolphin context-menu plugin (spec frontends/dolphin.md): the glue
// between the file manager and the testable parts beside this file.
#include <KAbstractFileItemActionPlugin>
#include <KFileItemListProperties>
#include <KPluginFactory>

#include <QAction>
#include <QClipboard>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QFile>
#include <QGuiApplication>
#include <QHash>
#include <QIcon>
#include <QUrl>
#include <QWidget>

#include "exchange.h"
#include "menu.h"
#include "resolve.h"
#include "tsync_mounts.h"

namespace {

/// NOTICE_TIMEOUT.
const int noticeTimeoutMs = 5000;

void collect(void *context, const char *mountPoint, size_t mountPointLength, const char *socket, size_t socketLength)
{
    static_cast<QList<tsync::Mount> *>(context)->append(
        {QByteArray(mountPoint, qsizetype(mountPointLength)), QByteArray(socket, qsizetype(socketLength))});
}

/// Notifications and the clipboard of the session. Nothing here waits for
/// the notification service.
class SessionDesktop : public QObject, public tsync::Desktop
{
public:
    using QObject::QObject;

    int startNotice(const QString &text) override
    {
        const int token = ++m_lastToken;
        m_ids.insert(token, 0);
        auto *watcher = new QDBusPendingCallWatcher(notify(text, 0, 0), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, token](QDBusPendingCallWatcher *finished) {
            const QDBusPendingReply<uint> reply = *finished;
            finished->deleteLater();
            const uint id = reply.isError() ? 0 : reply.value();
            const auto waiting = m_finals.constFind(token);
            if (waiting != m_finals.constEnd()) {
                notify(*waiting, id, noticeTimeoutMs);
                m_finals.remove(token);
                m_ids.remove(token);
            } else {
                m_ids[token] = id == 0 ? unknown : id;
            }
        });
        return token;
    }

    void finalNotice(const QString &text, int startToken) override
    {
        const uint id = m_ids.value(startToken, unknown);
        if (startToken != 0 && id == 0) {
            m_finals.insert(startToken, text);
            return;
        }
        m_ids.remove(startToken);
        notify(text, id == unknown ? 0 : id, noticeTimeoutMs);
    }

    void setClipboard(const QString &text) override
    {
        QGuiApplication::clipboard()->setText(text);
    }

private:
    /// A start notice whose id the service never gave.
    static constexpr uint unknown = ~0u;

    QDBusPendingCall notify(const QString &body, uint replaces, int expireMs)
    {
        QDBusMessage call = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("Notify"));
        call.setArguments({QStringLiteral("tsync"), replaces, QStringLiteral("tsync"), QStringLiteral("tsync"), body,
                           QStringList(), QVariantMap(), expireMs});
        return QDBusConnection::sessionBus().asyncCall(call);
    }

    int m_lastToken = 0;
    /// Start notices: 0 while the service has not answered with the id.
    QHash<int, uint> m_ids;
    /// Final notices waiting for the id of their start notice.
    QHash<int, QString> m_finals;
};

}

class TsyncDolphin : public KAbstractFileItemActionPlugin
{
    Q_OBJECT
public:
    explicit TsyncDolphin(QObject *parent)
        : KAbstractFileItemActionPlugin(parent)
        , m_desktop(new SessionDesktop(this))
    {
    }

    QList<QAction *> actions(const KFileItemListProperties &selection, QWidget *parentWidget) override
    {
        const QList<QUrl> urls = selection.urlList();
        if (urls.size() != 1 || !urls.first().isLocalFile())
            return {};
        QList<tsync::Mount> mounts;
        if (tsync_mounts_query(collect, &mounts) <= 0)
            return {};
        tsync::SystemLinkReader links;
        const tsync::Resolved item = tsync::resolve(QFile::encodeName(urls.first().toLocalFile()), mounts, links);
        if (!item.found)
            return {};
        const tsync::Timing timing;
        const tsync::ItemState state = tsync::statItem(item.mount.socket, item.rel, timing.statMs);
        QList<QAction *> actions;
        for (const tsync::MenuAction &offered : tsync::actionsFor(state)) {
            const QString icon = offered.kind == tsync::ActionKind::Share && !QIcon::hasThemeIcon(offered.icon)
                ? QStringLiteral("edit-link")
                : offered.icon;
            auto *action = new QAction(QIcon::fromTheme(icon), offered.label, parentWidget);
            const tsync::ActionKind kind = offered.kind;
            const bool directory = state.isDirectory();
            connect(action, &QAction::triggered, this, [this, kind, item, directory, timing] {
                (new tsync::ActionRun(kind, item.mount.socket, item.rel, item.displayName, directory, m_desktop, timing, this))->start();
            });
            actions.append(action);
        }
        return actions;
    }

private:
    SessionDesktop *m_desktop;
};

K_PLUGIN_CLASS_WITH_JSON(TsyncDolphin, "tsyncdolphin.json")

#include "plugin.moc"
