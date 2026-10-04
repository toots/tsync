// The plugin without a file manager (spec frontends/dolphin.md §7): mounts
// from the discovery stand-in, owners as socket doubles, a desktop that
// records. Prints what it checked; compared whole with logic_test.expected.
#include <KPluginMetaData>

#include <QCoreApplication>
#include <QDate>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QHash>
#include <QLocale>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include "exchange.h"
#include "menu.h"
#include "resolve.h"
#include "tsync_mounts.h"

using namespace tsync;

static QTextStream out(stdout);
static int checks = 0;

static void section(const QString &title)
{
    ++checks;
    out << "\n== " << title << "\n";
}

static const char *yes(bool value)
{
    return value ? "yes" : "NO";
}

static void collect(void *context, const char *mountPoint, size_t mountPointLength, const char *socket, size_t socketLength)
{
    static_cast<QList<Mount> *>(context)->append(
        {QByteArray(mountPoint, qsizetype(mountPointLength)), QByteArray(socket, qsizetype(socketLength))});
}

// Symbolic links by table, and a count of the questions asked at or below a
// mount point: on a mount whose owner is wedged each would hang.
class TableLinks : public LinkReader
{
public:
    TableLinks(const QList<Mount> &mounts, const QHash<QByteArray, QByteArray> &links)
        : m_mounts(mounts)
        , m_links(links)
    {
    }

    bool readLink(const QByteArray &path, QByteArray *target) override
    {
        ++asked;
        for (const Mount &mount : m_mounts)
            if (path == mount.mountPoint || path.startsWith(mount.mountPoint + '/'))
                ++askedBelowAMount;
        const auto found = m_links.constFind(path);
        if (found == m_links.constEnd())
            return false;
        *target = *found;
        return true;
    }

    int asked = 0;
    int askedBelowAMount = 0;

private:
    QList<Mount> m_mounts;
    QHash<QByteArray, QByteArray> m_links;
};

class RecordingDesktop : public Desktop
{
public:
    int startNotice(const QString &text) override
    {
        events << QStringLiteral("start notice #%1: %2").arg(++m_tokens).arg(text);
        return m_tokens;
    }

    void finalNotice(const QString &text, int startToken) override
    {
        ++finals;
        events << (startToken ? QStringLiteral("final notice, replacing #%1: %2").arg(startToken).arg(text)
                              : QStringLiteral("final notice: %1").arg(text));
    }

    void setClipboard(const QString &text) override
    {
        events << QStringLiteral("clipboard: %1").arg(text);
    }

    QStringList events;
    int finals = 0;

private:
    int m_tokens = 0;
};

static void spin(int milliseconds)
{
    QEventLoop loop;
    QTimer::singleShot(milliseconds, &loop, &QEventLoop::quit);
    loop.exec();
}

static bool waitFor(const std::function<bool()> &condition, int timeoutMs)
{
    QElapsedTimer timer;
    timer.start();
    while (!condition()) {
        if (timer.elapsed() > timeoutMs)
            return false;
        spin(10);
    }
    return true;
}

struct Owner {
    QByteArray socket;
    QString scripts;
    QProcess *process = nullptr;

    void script(const QString &action, const QByteArray &text) const
    {
        QFile file(scripts + '/' + action);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
            qFatal("cannot write a script");
        file.write(text);
    }
};

static QString ownerDouble;
static QDir scratch;

static Owner owner(const QString &name, const QString &mode)
{
    Owner started;
    started.socket = QFile::encodeName(scratch.filePath(name + ".sock"));
    started.scripts = scratch.filePath(name);
    scratch.mkpath(name);
    if (mode == "absent")
        return started;
    started.process = new QProcess(QCoreApplication::instance());
    started.process->start(ownerDouble, {mode, QFile::decodeName(started.socket), started.scripts});
    if (!waitFor([&] { return QFile::exists(QFile::decodeName(started.socket)); }, 5000))
        qFatal("an owner double did not start");
    return started;
}

static QString names(const QList<MenuAction> &actions)
{
    QStringList labels;
    for (const MenuAction &action : actions)
        labels << QStringLiteral("%1 (%2)").arg(action.label, action.icon);
    return labels.isEmpty() ? QStringLiteral("nothing") : labels.join(", ");
}

static void resolution(const QList<Mount> &mounts)
{
    section("resolution");
    const QHash<QByteArray, QByteArray> links = {
        {"/home/someone/shortcut", "/mnt/files/a"},
        {"/home/someone/relative", "../../mnt/files/media"},
        {"/home/loop", "/home/loop"},
    };
    int askedBelow = 0;
    for (const QByteArray &path : {QByteArray("/mnt/files/a/b.txt"), QByteArray("/mnt/files"), QByteArray("/mnt/files/"),
                                   QByteArray("/mnt/files/media/x.mkv"), QByteArray("/mnt/files-elsewhere/x"),
                                   QByteArray("/home/someone/x"), QByteArray("/home/someone/shortcut/deep/c.txt"),
                                   QByteArray("/home/someone/relative/y.mkv"), QByteArray("/mnt/spaced name/z"),
                                   QByteArray("/mnt/files/./a//../b"), QByteArray("/home/loop/x")}) {
        TableLinks reader(mounts, links);
        const Resolved item = resolve(path, mounts, reader);
        askedBelow += reader.askedBelowAMount;
        if (item.found)
            out << path << " -> " << item.mount.mountPoint << ", rel \"" << item.rel << "\", name \"" << item.displayName << "\", socket "
                << item.mount.socket << "\n";
        else
            out << path << " -> no mount\n";
    }
    TableLinks reader({}, links);
    out << "with no mounts: " << (resolve("/mnt/files/a", {}, reader).found ? "A MOUNT" : "no mount") << ", " << reader.asked
        << " questions asked\n";
    out << "questions asked at or below a mount point: " << askedBelow << "\n";
}

static void menus()
{
    section("menu");
    const auto row = [](const char *kind, const char *availability) {
        ItemState state;
        state.outcome = ItemState::Row;
        state.kind = kind;
        state.availability = availability;
        return state;
    };
    out << "file, online-only: " << names(actionsFor(row("file", "online-only"))) << "\n";
    out << "file, cached: " << names(actionsFor(row("file", "cached"))) << "\n";
    out << "file, pinned: " << names(actionsFor(row("file", "pinned"))) << "\n";
    out << "directory: " << names(actionsFor(row("dir", ""))) << "\n";
    out << "symlink: " << names(actionsFor(row("symlink", ""))) << "\n";
    ItemState state;
    state.outcome = ItemState::NotFound;
    out << "not_found: " << names(actionsFor(state)) << "\n";
    state.outcome = ItemState::Unknown;
    out << "no answer: " << names(actionsFor(state)) << "\n";
}

static void stats()
{
    section("stat while the menu is built");
    const Timing timing;
    const Owner scripted = owner("stat", "scripted");
    scripted.script("stat", "{\"ok\":true,\"kind\":\"file\",\"availability\":\"cached\"}\n");
    out << "a row: " << names(actionsFor(statItem(scripted.socket, "a/b.txt", timing.statMs))) << "\n";
    scripted.script("stat", "{\"ok\":false,\"code\":\"not_found\",\"error\":\"no such item\"}\n");
    out << "refused not_found: " << names(actionsFor(statItem(scripted.socket, "gone", timing.statMs))) << "\n";
    scripted.script("stat", "{\"ok\":false,\"code\":\"internal\",\"error\":\"busy\"}\n");
    out << "another refusal: " << names(actionsFor(statItem(scripted.socket, "a", timing.statMs))) << "\n";
    scripted.script("stat", "[1,2]\n");
    out << "a reply that is not an object: " << names(actionsFor(statItem(scripted.socket, "a", timing.statMs))) << "\n";
    QFile requests(scripted.scripts + "/requests");
    if (requests.open(QIODevice::ReadOnly))
        out << "the first request: " << requests.readLine().trimmed() << "\n";
    for (const QString &mode : {QStringLiteral("silent"), QStringLiteral("trickle"), QStringLiteral("absent")}) {
        const Owner wedged = owner("wedged-" + mode, mode);
        QElapsedTimer timer;
        timer.start();
        const ItemState state = statItem(wedged.socket, "a/b.txt", timing.statMs);
        const qint64 elapsed = timer.elapsed();
        // A client with no deadline over the whole exchange never returns from
        // the trickling owner; the margin only has to tell that apart.
        out << "an owner that is " << mode << ": " << names(actionsFor(state)) << "; ended by its deadline: "
            << yes(elapsed <= timing.statMs + 5000) << "\n";
    }
}

static void requests()
{
    section("requests");
    for (ActionKind kind : {ActionKind::Share, ActionKind::Restore, ActionKind::Evict})
        out << ActionRun::requestLine(kind, "sub dir/a b.txt") << "\n";
    out << ActionRun::requestLine(ActionKind::Share, "") << "\n";
}

static void click(const QString &title, ActionKind kind, bool directory, const Owner &target, const std::function<void()> &during = {})
{
    Timing timing;
    timing.requestMs = 600;
    timing.probeIntervalMs = 300;
    timing.probeDeadlineMs = 300;
    RecordingDesktop desktop;
    (new ActionRun(kind, target.socket, "docs/report.pdf", directory ? "docs" : "report.pdf", directory, &desktop, timing,
                   QCoreApplication::instance()))
        ->start();
    if (during)
        QTimer::singleShot(450, during);
    waitFor([&] { return desktop.finals > 0; }, 5000);
    spin(700);
    // How a locale writes a date differs between Qt versions; that the notice
    // carries the expiry in the user's locale is what is checked.
    const QString expiry = QLocale().toString(QDate(2030, 1, 1), QLocale::ShortFormat);
    out << title << ": " << desktop.finals << " final\n";
    for (QString event : desktop.events)
        out << "    " << event.replace(expiry, QStringLiteral("<1 January 2030 in the locale>")) << "\n";
}

static void clicks()
{
    section("clicks");
    const Owner good = owner("good", "scripted");
    good.script("share", "{\"ok\":true,\"url\":\"https://files.example/s/abc\",\"expires\":1893456000}\n");
    good.script("restore", "{\"ok\":true,\"restored\":12,\"failed\":0}\n");
    good.script("evict", "{\"ok\":true,\"evicted\":7,\"failed\":2}\n");
    const Owner refusing = owner("refusing", "scripted");
    refusing.script("share", "{\"ok\":false,\"code\":\"paused\",\"error\":\"Changes are held: resume to share.\"}\n");
    refusing.script("restore", "{\"ok\":false,\"code\":\"internal\"}\n");
    refusing.script("evict", "{\"ok\":false,\"code\":\"internal\",\"error\":\"\"}\n");
    const Owner silent = owner("silent", "silent");
    const Owner absent = owner("absent", "absent");
    const Owner fading = owner("fading", "scripted");
    for (const QString &action : {QStringLiteral("share"), QStringLiteral("restore"), QStringLiteral("evict")})
        fading.script(action, "silent\n");

    const struct {
        const char *name;
        ActionKind kind;
        bool directory;
    } actions[] = {
        {"share", ActionKind::Share, false},
        {"restore, file", ActionKind::Restore, false},
        {"restore, directory", ActionKind::Restore, true},
        {"evict, file", ActionKind::Evict, false},
        {"evict, directory", ActionKind::Evict, true},
    };
    for (const auto &action : actions) {
        click(QStringLiteral("%1, an owner that succeeds").arg(action.name), action.kind, action.directory, good);
        click(QStringLiteral("%1, an owner that refuses").arg(action.name), action.kind, action.directory, refusing);
        click(QStringLiteral("%1, an owner that is not listening").arg(action.name), action.kind, action.directory, absent);
        click(QStringLiteral("%1, an owner that accepts and never answers").arg(action.name), action.kind, action.directory, silent);
        if (isBulk(action.kind, action.directory)) {
            QFile::remove(fading.scripts + "/ping");
            click(QStringLiteral("%1, an owner that stops answering the probe mid-way").arg(action.name), action.kind,
                  action.directory, fading, [&] { fading.script("ping", "silent\n"); });
        }
    }
    good.script("restore", "{\"ok\":true,\"restored\":3,\"failed\":1}\n");
    click(QStringLiteral("restore, directory, some files failing"), ActionKind::Restore, true, good);
    good.script("share", "close\n{\"ok\":true,\"url\":\"https://files.example/s/abc\",\"expires\":1893456000}\n");
    click(QStringLiteral("share, an owner that answers and hangs up"), ActionKind::Share, false, good);
    good.script("evict", "close\n{\"ok\":false,\"code\":\"internal\",\"error\":\"The disk is full.\"}\n");
    click(QStringLiteral("evict, directory, an owner that refuses and hangs up"), ActionKind::Evict, true, good);
    good.script("share", "hangup\n");
    click(QStringLiteral("share, an owner that hangs up without answering"), ActionKind::Share, false, good);
    good.script("restore", "hangup\n");
    click(QStringLiteral("restore, directory, an owner that hangs up without answering"), ActionKind::Restore, true, good);
    good.script("restore", "wait 1\n{\"ok\":true,\"restored\":3,\"failed\":0}\n");
    click(QStringLiteral("restore, directory, answered after three probes"), ActionKind::Restore, true, good);
}

static void metadata(const QString &plugin)
{
    section("metadata");
    const KPluginMetaData data(plugin);
    out << "valid: " << yes(data.isValid()) << "\n";
    out << "name: " << data.name() << "\n";
    out << "types: " << data.mimeTypes().join(", ") << "\n";
    out << "file: " << QFileInfo(plugin).fileName() << "\n";
}

int main(int argc, char **argv)
{
    qputenv("TZ", "UTC");
    QCoreApplication application(argc, argv);
    QLocale::setDefault(QLocale::c());
    if (argc < 3)
        qFatal("usage: logic_test PLUGIN OWNER_DOUBLE");
    ownerDouble = QString::fromLocal8Bit(argv[2]);
    scratch = QDir(QStringLiteral("/tmp/tsync-dolphin-%1").arg(QCoreApplication::applicationPid()));
    scratch.mkpath(".");

    QList<Mount> mounts;
    section("the discovery stand-in");
    out << tsync_mounts_query(collect, &mounts) << " pairs\n";
    for (const Mount &mount : mounts)
        out << "[" << mount.mountPoint << "] [" << mount.socket << "]\n";

    resolution(mounts);
    menus();
    stats();
    requests();
    clicks();
    metadata(QString::fromLocal8Bit(argv[1]));

    for (QProcess *process : application.findChildren<QProcess *>()) {
        process->kill();
        process->waitForFinished();
    }
    scratch.removeRecursively();
    if (checks == 0)
        qFatal("no check ran");
    out << "\n" << checks << " sections\n";
    return 0;
}
