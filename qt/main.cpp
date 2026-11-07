#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // QSettings (the server URL) is stored under these names
    QCoreApplication::setOrganizationName("worklog");
    QCoreApplication::setApplicationName("WorkLogApp");
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

    return QGuiApplication::exec();
}
