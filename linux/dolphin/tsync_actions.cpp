#include "tsync_mounts.h"

#include <KAbstractFileItemActionPlugin>
#include <KFileItemListProperties>
#include <KPluginFactory>

#include <QAction>
#include <QClipboard>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDeadlineTimer>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QUrl>
#include <QWidget>

#include <functional>
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

QByteArray line(const QJsonObject &request)
{
    return QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n';
}

// A share reaches the store and a restore reaches the network, so the click
// returns and the answer arrives on the socket's own signals rather than the
// menu waiting on it. A refusal is a reply, so it is shown as one.
void request(const TsyncMount &mount, const QJsonObject &request,
             std::function<void(const QJsonObject &)> onReply)
{
    auto *sock = new QLocalSocket;
    auto buffer = std::make_shared<QByteArray>();

    QObject::connect(sock, &QLocalSocket::connected, sock,
                     [sock, request]() { sock->write(line(request)); });

    QObject::connect(sock, &QLocalSocket::readyRead, sock,
                     [sock, buffer, onReply]() {
                         *buffer += sock->readAll();
                         if (!buffer->endsWith('\n')) {
                             return;
                         }
                         sock->deleteLater();
                         const QJsonObject reply =
                             QJsonDocument::fromJson(*buffer).object();
                         if (!reply.value(QStringLiteral("ok")).toBool()) {
                             const QString error =
                                 reply.value(QStringLiteral("error")).toString();
                             notify(error.isEmpty() ? QObject::tr("The daemon refused.")
                                                    : error);
                             return;
                         }
                         onReply(reply);
                     });

    QObject::connect(sock, &QLocalSocket::errorOccurred, sock,
                     [sock](QLocalSocket::LocalSocketError) {
                         notify(sock->errorString());
                         sock->deleteLater();
                     });

    sock->connectToServer(mount.socket);
}

// The same, waited for: what the menu offers depends on the answer, and a menu
// is drawn once. Bounded so a daemon that is away costs a beat, not a hang;
// an empty object is "no answer", and the menu then offers what it can
// without one.
QJsonObject requestNow(const TsyncMount &mount, const QJsonObject &request)
{
    QLocalSocket sock;
    sock.connectToServer(mount.socket);
    if (!sock.waitForConnected(200)) {
        return {};
    }
    sock.write(line(request));
    QByteArray buffer;
    QDeadlineTimer deadline(300);
    while (!buffer.endsWith('\n')) {
        if (deadline.hasExpired()
            || !sock.waitForReadyRead(int(deadline.remainingTime()))) {
            return {};
        }
        buffer += sock.readAll();
    }
    return QJsonDocument::fromJson(buffer).object();
}

QString itemName(const QString &rel)
{
    return rel.isEmpty() ? QObject::tr("The folder") : QFileInfo(rel).fileName();
}

}

class TsyncActions : public KAbstractFileItemActionPlugin
{
    Q_OBJECT

public:
    TsyncActions(QObject *parent, const QVariantList &)
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
        const QString name = itemName(rel);
        QList<QAction *> actions;

        // The application icon comes from whichever tsync package installed
        // one, and a theme that has none still has a link icon.
        auto *share =
            new QAction(QIcon::fromTheme(QStringLiteral("tsync"),
                                         QIcon::fromTheme(QStringLiteral("edit-link"))),
                        tr("Copy Share Link"), parentWidget);
        QObject::connect(share, &QAction::triggered, share, [mount, rel]() {
            request(mount,
                    {{QStringLiteral("action"), QStringLiteral("share")},
                     {QStringLiteral("rel"), rel}},
                    [](const QJsonObject &reply) {
                        QGuiApplication::clipboard()->setText(
                            reply.value(QStringLiteral("url")).toString());
                        notify(QObject::tr("Share link copied to the clipboard."));
                    });
        });
        actions << share;

        // Where the bytes are decides what is offered. A directory says nothing
        // and gets both; a daemon that does not answer gets neither, since an
        // action on an item whose state is unknown is a guess.
        const QJsonObject item = requestNow(
            mount, {{QStringLiteral("action"), QStringLiteral("stat")},
                    {QStringLiteral("rel"), rel}});
        if (!item.value(QStringLiteral("ok")).toBool()) {
            return actions;
        }
        const QString availability =
            item.value(QStringLiteral("availability")).toString();
        const bool pinned = availability == QStringLiteral("pinned");

        auto *offline = new QAction(
            QIcon::fromTheme(QStringLiteral("cloud-download")),
            pinned ? tr("Keep Offline Longer") : tr("Make Available Offline"),
            parentWidget);
        QObject::connect(offline, &QAction::triggered, offline, [mount, rel, name]() {
            request(mount,
                    {{QStringLiteral("action"), QStringLiteral("restore")},
                     {QStringLiteral("rel"), rel}},
                    [name](const QJsonObject &) {
                        notify(QObject::tr("%1 is available offline.").arg(name));
                    });
        });
        actions << offline;

        if (availability != QStringLiteral("online-only")) {
            auto *online = new QAction(
                QIcon::fromTheme(QStringLiteral("cloud-upload")),
                tr("Make Online Only"), parentWidget);
            QObject::connect(online, &QAction::triggered, online, [mount, rel, name]() {
                request(mount,
                        {{QStringLiteral("action"), QStringLiteral("evict")},
                         {QStringLiteral("rel"), rel}},
                        [name](const QJsonObject &) {
                            notify(QObject::tr("%1 is online only.").arg(name));
                        });
            });
            actions << online;
        }
        return actions;
    }
};

K_PLUGIN_CLASS_WITH_JSON(TsyncActions, "tsyncactions.json")

#include "tsync_actions.moc"
