#include "exchange.h"

#include <QFile>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QTimer>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

namespace tsync {

Reply parseReply(const QByteArray &line)
{
    Reply reply;
    const QJsonDocument document = QJsonDocument::fromJson(line);
    if (!document.isObject())
        return reply;
    reply.fields = document.object();
    if (reply.fields.value(QLatin1String("ok")).toBool(false)) {
        reply.kind = Reply::Answer;
    } else {
        reply.kind = Reply::Refusal;
        reply.code = reply.fields.value(QLatin1String("code")).toString();
        reply.error = reply.fields.value(QLatin1String("error")).toString();
    }
    return reply;
}

static QByteArray line(const QJsonObject &request)
{
    return QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n';
}

static qint64 nowMs()
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return qint64(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
}

// Waits for the descriptor until the deadline, an absolute time that no byte
// received pushes back.
static bool waitFor(int descriptor, short events, qint64 deadline)
{
    for (;;) {
        const qint64 remaining = deadline - nowMs();
        if (remaining <= 0)
            return false;
        struct pollfd waited = {descriptor, events, 0};
        const int ready = poll(&waited, 1, int(remaining));
        if (ready > 0)
            return true;
        if (ready < 0 && errno != EINTR)
            return false;
    }
}

Reply exchangeBlocking(const QByteArray &socket, const QJsonObject &request, int deadlineMs)
{
    const qint64 deadline = nowMs() + deadlineMs;
    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    if (size_t(socket.size()) >= sizeof address.sun_path)
        return Reply();
    memcpy(address.sun_path, socket.constData(), size_t(socket.size()));
    const int descriptor = ::socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (descriptor < 0)
        return Reply();
    Reply reply;
    QByteArray received;
    const QByteArray sent = line(request);
    qsizetype written = 0;
    if (::connect(descriptor, reinterpret_cast<struct sockaddr *>(&address), sizeof address) != 0) {
        if (errno != EINPROGRESS && errno != EAGAIN)
            goto done;
        if (errno == EAGAIN || !waitFor(descriptor, POLLOUT, deadline))
            goto done;
        int failure = 0;
        socklen_t length = sizeof failure;
        if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) != 0 || failure != 0)
            goto done;
    }
    while (written < sent.size()) {
        const ssize_t count = ::send(descriptor, sent.constData() + written, size_t(sent.size() - written), MSG_NOSIGNAL);
        if (count > 0)
            written += count;
        else if (errno == EAGAIN || errno == EINTR) {
            if (!waitFor(descriptor, POLLOUT, deadline))
                goto done;
        } else
            goto done;
    }
    for (;;) {
        char chunk[4096];
        const ssize_t count = ::read(descriptor, chunk, sizeof chunk);
        if (count > 0) {
            received.append(chunk, count);
            const qsizetype end = received.indexOf('\n');
            if (end >= 0) {
                reply = parseReply(received.left(end));
                goto done;
            }
            if (nowMs() >= deadline)
                goto done;
        } else if (count == 0) {
            goto done;
        } else if (errno == EAGAIN || errno == EINTR) {
            if (!waitFor(descriptor, POLLIN, deadline))
                goto done;
        } else {
            goto done;
        }
    }
done:
    ::close(descriptor);
    return reply;
}

ItemState statItem(const QByteArray &socket, const QByteArray &rel, int deadlineMs)
{
    QJsonObject request;
    request.insert(QLatin1String("action"), QLatin1String("stat"));
    request.insert(QLatin1String("rel"), QString::fromUtf8(rel));
    const Reply reply = exchangeBlocking(socket, request, deadlineMs);
    ItemState state;
    if (reply.kind == Reply::Answer) {
        state.outcome = ItemState::Row;
        state.kind = reply.fields.value(QLatin1String("kind")).toString();
        state.availability = reply.fields.value(QLatin1String("availability")).toString();
    } else if (reply.kind == Reply::Refusal && reply.code == QLatin1String("not_found")) {
        state.outcome = ItemState::NotFound;
    }
    return state;
}

ActionRun::ActionRun(ActionKind kind, const QByteArray &socket, const QByteArray &rel, const QString &name,
                     bool directory, Desktop *desktop, const Timing &timing, QObject *parent)
    : QObject(parent)
    , m_kind(kind)
    , m_socketPath(socket)
    , m_rel(rel)
    , m_name(name)
    , m_directory(directory)
    , m_desktop(desktop)
    , m_timing(timing)
{
}

QByteArray ActionRun::requestLine(ActionKind kind, const QByteArray &rel)
{
    QJsonObject request;
    request.insert(QLatin1String("action"), actionName(kind));
    request.insert(QLatin1String("rel"), QString::fromUtf8(rel));
    return QJsonDocument(request).toJson(QJsonDocument::Compact);
}

void ActionRun::start()
{
    const QString starting = startNotice(m_kind, m_directory, m_name);
    if (!starting.isEmpty())
        m_startToken = m_desktop->startNotice(starting);
    m_socket = new QLocalSocket(this);
    connect(m_socket, &QLocalSocket::connected, this, [this] {
        m_socket->write(requestLine(m_kind, m_rel) + '\n');
    });
    connect(m_socket, &QLocalSocket::readyRead, this, &ActionRun::received);
    connect(m_socket, &QLocalSocket::errorOccurred, this, [this] {
        finish(noAnswerNotice(m_kind, m_directory, m_name));
    });
    connect(m_socket, &QLocalSocket::disconnected, this, [this] {
        finish(noAnswerNotice(m_kind, m_directory, m_name));
    });
    if (isBulk(m_kind, m_directory)) {
        auto *probes = new QTimer(this);
        connect(probes, &QTimer::timeout, this, &ActionRun::probe);
        probes->start(m_timing.probeIntervalMs);
    } else {
        QTimer::singleShot(m_timing.requestMs, this, [this] {
            finish(noAnswerNotice(m_kind, m_directory, m_name));
        });
    }
    m_socket->connectToServer(QFile::decodeName(m_socketPath));
}

void ActionRun::received()
{
    m_received += m_socket->readAll();
    const qsizetype end = m_received.indexOf('\n');
    if (end < 0)
        return;
    const Reply reply = parseReply(m_received.left(end));
    switch (reply.kind) {
    case Reply::Answer:
        if (m_kind == ActionKind::Share)
            m_desktop->setClipboard(reply.fields.value(QLatin1String("url")).toString());
        finish(successNotice(m_kind, m_directory, m_name, reply.fields));
        break;
    case Reply::Refusal:
        finish(refusalNotice(reply.error));
        break;
    case Reply::NoAnswer:
        finish(noAnswerNotice(m_kind, m_directory, m_name));
        break;
    }
}

// The liveness probe of a bulk request: its own connection, its own deadline.
void ActionRun::probe()
{
    auto *socket = new QLocalSocket(this);
    auto *deadline = new QTimer(socket);
    deadline->setSingleShot(true);
    auto missed = [this] {
        finish(noAnswerNotice(m_kind, m_directory, m_name));
    };
    connect(deadline, &QTimer::timeout, this, missed);
    connect(socket, &QLocalSocket::errorOccurred, this, missed);
    connect(socket, &QLocalSocket::connected, socket, [socket] {
        socket->write("{\"action\":\"ping\"}\n");
    });
    connect(socket, &QLocalSocket::readyRead, socket, [socket, deadline, missed] {
        if (!socket->canReadLine())
            return;
        deadline->stop();
        const bool answered = parseReply(socket->readLine().trimmed()).kind == Reply::Answer;
        socket->disconnect();
        socket->deleteLater();
        if (!answered)
            missed();
    });
    deadline->start(m_timing.probeDeadlineMs);
    socket->connectToServer(QFile::decodeName(m_socketPath));
}

void ActionRun::finish(const QString &notice)
{
    if (m_finished)
        return;
    m_finished = true;
    m_desktop->finalNotice(notice, m_startToken);
    deleteLater();
}

}
