// Requests to a domain's owner (spec frontends/dolphin.md §3, §4;
// frontends/linux-desktop.md §4.1).
#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>

#include "menu.h"

class QLocalSocket;
class QTimer;

namespace tsync {

struct Reply {
    enum Kind { Answer, Refusal, NoAnswer } kind = NoAnswer;
    QJsonObject fields;
    QString code;
    QString error;
};

/// A reply line as the transport rules read it: anything that is not one JSON
/// object is no answer.
Reply parseReply(const QByteArray &line);

/// One exchange on the calling thread, under one deadline covering the
/// connection, the request and the whole reply line.
Reply exchangeBlocking(const QByteArray &socket, const QJsonObject &request, int deadlineMs);

/// `stat` for an item of the mount.
ItemState statItem(const QByteArray &socket, const QByteArray &rel, int deadlineMs);

struct Timing {
    /// PLUGIN_STAT_DEADLINE.
    int statMs = 500;
    /// REQUEST_DEADLINE + CLIENT_DEADLINE_MARGIN.
    int requestMs = 35000;
    /// LIVENESS_INTERVAL and LIVENESS_DEADLINE.
    int probeIntervalMs = 10000;
    int probeDeadlineMs = 5000;
};

/// What a click shows its user. A start notice answers a token, which the
/// final notice of the same action hands back so that it replaces it.
class Desktop
{
public:
    virtual ~Desktop() = default;
    virtual int startNotice(const QString &text) = 0;
    virtual void finalNotice(const QString &text, int startToken) = 0;
    virtual void setClipboard(const QString &text) = 0;
};

/// One click: its own connection, its own notices, exactly one final notice.
/// It runs on the event loop and deletes itself when done.
class ActionRun : public QObject
{
    Q_OBJECT
public:
    ActionRun(ActionKind kind, const QByteArray &socket, const QByteArray &rel, const QString &name,
              bool directory, Desktop *desktop, const Timing &timing, QObject *parent);

    /// The request line this click sends, without its newline.
    static QByteArray requestLine(ActionKind kind, const QByteArray &rel);

    void start();

private:
    void received();
    void probe();
    void finish(const QString &notice);

    ActionKind m_kind;
    QByteArray m_socketPath;
    QByteArray m_rel;
    QString m_name;
    bool m_directory;
    Desktop *m_desktop;
    Timing m_timing;
    QLocalSocket *m_socket = nullptr;
    QByteArray m_received;
    int m_startToken = 0;
    bool m_finished = false;
};

}
