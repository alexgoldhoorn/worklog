#include "singleinstance.h"

#include <QLocalSocket>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

SingleInstance::SingleInstance(QObject *parent) : QObject(parent)
{
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    connect(&m_server, &QLocalServer::newConnection, this, [this]() {
        while (QLocalSocket *s = m_server.nextPendingConnection()) {
            connect(s, &QLocalSocket::readyRead, s, [this, s]() {
                if (s->readAll().startsWith("show"))
                    emit showRequested();
                s->disconnectFromServer();
            });
            connect(s, &QLocalSocket::disconnected, s, &QObject::deleteLater);
        }
    });
}

bool SingleInstance::notifyRunning(const QString &name, bool showOther)
{
    QLocalSocket sock;
    sock.connectToServer(name);
    if (!sock.waitForConnected(500))
        return false;
#ifdef Q_OS_WIN
    AllowSetForegroundWindow(ASFW_ANY);   // this process was just launched by the user: let the other one come to the front
#endif
    sock.write(showOther ? "show" : "quiet");
    sock.flush();
    sock.waitForBytesWritten(500);
    sock.disconnectFromServer();
    return true;
}

bool SingleInstance::acquire(const QString &name, bool showOther)
{
    if (notifyRunning(name, showOther))
        return false;
    // nobody answered: any leftover socket file (Unix, after a crash) is stale
    QLocalServer::removeServer(name);
    if (m_server.listen(name))
        return true;
    // lost a race against another launch that listened a moment ago
    return !notifyRunning(name, showOther);
}
