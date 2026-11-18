#pragma once

#include <QLocalServer>
#include <QObject>
#include <QString>

// One running copy per user: the first process listens on a local socket, a second one connects, asks
// the first to show its window ("show") or just exits quietly ("quiet", for the autostart launch).
class SingleInstance : public QObject
{
    Q_OBJECT
public:
    explicit SingleInstance(QObject *parent = nullptr);

    // true: this process is the first and now listens. false: another copy answered and was told
    // what to do; the caller should exit.
    bool acquire(const QString &name, bool showOther);

signals:
    void showRequested();

private:
    bool notifyRunning(const QString &name, bool showOther);
    QLocalServer m_server;
};
