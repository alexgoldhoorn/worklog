#ifdef _WIN32
#include <QApplication>   // Qt Labs Platform's tray icon and menu need Widgets
#else
#include <QGuiApplication>
#endif
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>

#ifndef Q_OS_ANDROID
#include "singleinstance.h"
#endif

int main(int argc, char *argv[])
{
#ifdef _WIN32
    QApplication app(argc, argv);
#else
    QGuiApplication app(argc, argv);
#endif
    // QSettings (the server URL) is stored under these names
    // WORKLOG_ORG lets a scratch copy run beside the real one (own settings, own instance lock, own Run entry)
    QCoreApplication::setOrganizationName(qEnvironmentVariable("WORKLOG_ORG", "worklog"));
    QCoreApplication::setApplicationName("WorkLogApp");
#ifdef WORKLOG_VERSION
    QCoreApplication::setApplicationVersion(QStringLiteral(WORKLOG_VERSION));
#endif
#ifdef Q_OS_WIN
    // the window hides to the tray instead of closing (TrayController); Main.qml quits explicitly
    app.setQuitOnLastWindowClosed(false);
#endif

#ifndef Q_OS_ANDROID
    // Closing the window leaves the app in the tray, so a second launch must wake that copy, not
    // start another one (second tray icon, hotkey already taken). The autostart launch is quiet.
    SingleInstance single;
    const QString lockName = QStringLiteral("%1-%2-%3").arg(
        QCoreApplication::organizationName(), QCoreApplication::applicationName(),
        qEnvironmentVariable("USERNAME", qEnvironmentVariable("USER")));
    if (!single.acquire(lockName, !app.arguments().contains(QStringLiteral("--minimized"))))
        return 0;
#endif

    QQuickStyle::setStyle("Material");
    QGuiApplication::setWindowIcon(QIcon(":/qt/qml/WorkLogApp/icons/worklog-256.png"));

    QQmlApplicationEngine engine;
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("WorkLogApp", "Main");

#ifndef Q_OS_ANDROID
    QObject::connect(&single, &SingleInstance::showRequested, &app, [&engine]() {
        for (QObject *o : engine.rootObjects()) {
            if (auto *w = qobject_cast<QQuickWindow *>(o)) {
                if (w->visibility() == QWindow::Minimized)
                    w->showNormal();
                else
                    w->show();
                w->raise();
                w->requestActivate();
            }
        }
    });
#endif

    return app.exec();
}
