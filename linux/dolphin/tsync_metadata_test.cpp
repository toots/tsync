// The plugin's own metadata, read back the way KIO reads it. A key in the wrong
// place leaves a plugin that loads, matches nothing and reports no error.

#include <KPluginMetaData>

#include <QCoreApplication>
#include <QTextStream>

namespace {

int checks = 0;
int failures = 0;

void check(bool ok, const QString &what)
{
    ++checks;
    QTextStream out(stdout);
    if (ok) {
        out << "  ok   " << what << "\n";
    } else {
        ++failures;
        out << "  FAIL " << what << "\n";
    }
}

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc < 2) {
        QTextStream(stderr) << "usage: tsync_metadata_test <plugin.so>\n";
        return 1;
    }

    const KPluginMetaData metadata(QString::fromLocal8Bit(argv[1]));
    check(metadata.isValid(), QStringLiteral("the plugin carries metadata"));
    check(!metadata.name().isEmpty(), QStringLiteral("it names itself"));

    const QStringList mimeTypes = metadata.mimeTypes();
    check(mimeTypes.contains(QStringLiteral("application/octet-stream")),
          QStringLiteral("it offers itself for files"));
    check(mimeTypes.contains(QStringLiteral("inode/directory")),
          QStringLiteral("it offers itself for folders"));

    QTextStream out(stdout);
    out << "\n" << (checks - failures) << "/" << checks << " checks passed\n";
    return failures == 0 && checks > 0 ? 0 : 1;
}
