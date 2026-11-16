// Qt Quick Test runner. The tests need a worklog server: run_tests.py starts one on a temporary
// database and passes its address in WORKLOG_TEST_URL (-> `testServer` in the QML tests).
#include <QtQuickTest>
#include <QQmlEngine>
#include <QQmlContext>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QQuickStyle>

class Setup : public QObject
{
    Q_OBJECT
public:
    Setup()
    {
        // never touch the user's real saved URL and login (registry on Windows)
        QCoreApplication::setOrganizationName("worklog-test");
        QCoreApplication::setApplicationName("WorkLogAppTest");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_dir.path());
        QQuickStyle::setStyle("Material");
    }

public slots:
    void qmlEngineAvailable(QQmlEngine *engine)
    {
        engine->rootContext()->setContextProperty("testServer", qEnvironmentVariable("WORKLOG_TEST_URL"));
    }

private:
    QTemporaryDir m_dir;
};

QUICK_TEST_MAIN_WITH_SETUP(tst_worklog, Setup)

#include "tst_main.moc"
