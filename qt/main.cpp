#ifdef _WIN32
#include <QApplication>   // Qt Labs Platform's tray icon and menu need Widgets
#else
#include <QGuiApplication>
#endif
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>

int main(int argc, char *argv[])
{
#ifdef _WIN32
    QApplication app(argc, argv);
#else
    QGuiApplication app(argc, argv);
#endif
    // QSettings (the server URL) is stored under these names
    QCoreApplication::setOrganizationName("worklog");
    QCoreApplication::setApplicationName("WorkLogApp");
#ifdef Q_OS_WIN
    // the window hides to the tray instead of closing (TrayController); Main.qml quits explicitly
    app.setQuitOnLastWindowClosed(false);
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

    return app.exec();
}
