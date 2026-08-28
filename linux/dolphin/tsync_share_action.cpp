#include "tsync_mounts.h"

#include <KAbstractFileItemActionPlugin>
#include <KFileItemListProperties>
#include <KPluginFactory>

#include <QAction>
#include <QClipboard>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QUrl>
#include <QWidget>

#include <memory>

namespace {

void notify(const QString &body)
{
    QDBusMessage msg = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.Notifications"),
        QStringLiteral("/org/freedesktop/Notifications"),
        QStringLiteral("org.freedesktop.Notifications"),
        QStringLiteral("Notify"));
    msg << QStringLiteral("tsync") << 0u << QStringLiteral("edit-link")
        << QStringLiteral("tsync") << body << QStringList() << QVariantMap()
        << 5000;
    QDBusConnection::sessionBus().asyncCall(msg);
}

// Publishing reaches the store, so the click returns and the answer arrives on
// the socket's own signals rather than the menu waiting on it.
void requestShare(const TsyncMount &mount, const QString &rel)
{
    auto *sock = new QLocalSocket;
    auto buffer = std::make_shared<QByteArray>();

    QObject::connect(sock, &QLocalSocket::connected, sock, [sock, mount, rel]() {
        const QJsonObject request{
            {QStringLiteral("action"), QStringLiteral("share")},
            {QStringLiteral("rel"), rel}};
        sock->write(QJsonDocument(request).toJson(QJsonDocument::Compact));
        sock->write("\n");
    });

    QObject::connect(sock, &QLocalSocket::readyRead, sock, [sock, buffer]() {
        *buffer += sock->readAll();
        if (!buffer->endsWith('\n')) {
            return;
        }
        sock->deleteLater();
        const QJsonObject reply = QJsonDocument::fromJson(*buffer).object();
        const QString url = reply.value(QStringLiteral("url")).toString();
        if (url.isEmpty()) {
            const QString error = reply.value(QStringLiteral("error")).toString();
            notify(error.isEmpty() ? QObject::tr("The share was refused.") : error);
            return;
        }
        QGuiApplication::clipboard()->setText(url);
        notify(QObject::tr("Share link copied to the clipboard."));
    });

    QObject::connect(sock, &QLocalSocket::errorOccurred, sock,
                     [sock](QLocalSocket::LocalSocketError) {
                         notify(sock->errorString());
                         sock->deleteLater();
                     });

    sock->connectToServer(mount.socket);
}

}

class TsyncShareAction : public KAbstractFileItemActionPlugin
{
    Q_OBJECT

public:
    TsyncShareAction(QObject *parent, const QVariantList &)
        : KAbstractFileItemActionPlugin(parent)
    {
    }

    QList<QAction *> actions(const KFileItemListProperties &properties,
                             QWidget *parentWidget) override
    {
        const QList<QUrl> urls = properties.urlList();
        if (urls.size() != 1 || !urls.first().isLocalFile()) {
            return {};
        }
        TsyncMount mount;
        QString rel;
        if (!tsyncResolve(tsyncMounts(), urls.first().toLocalFile(), &mount,
                          &rel)) {
            return {};
        }
        // The application icon comes from whichever tsync package installed
        // one, and a theme that has none still has a link icon.
        auto *action =
            new QAction(QIcon::fromTheme(QStringLiteral("tsync"),
                                         QIcon::fromTheme(QStringLiteral("edit-link"))),
                        tr("Copy Share Link"), parentWidget);
        QObject::connect(action, &QAction::triggered, action,
                         [mount, rel]() { requestShare(mount, rel); });
        return {action};
    }
};

K_PLUGIN_CLASS_WITH_JSON(TsyncShareAction, "tsyncshare.json")

#include "tsync_share_action.moc"
