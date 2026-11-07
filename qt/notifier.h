#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// A notification at a set time, also when the app is in the background (Android's AlarmManager, see
// android/src/.../PomodoroAlarm.java). Elsewhere it does nothing: the desktop window stays alive.
class Notifier : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Notifier(QObject *parent = nullptr);

    // replaces an earlier one; `atMs` is milliseconds since the epoch
    Q_INVOKABLE void schedule(qint64 atMs, const QString &title, const QString &text);
    Q_INVOKABLE void cancel();
};
