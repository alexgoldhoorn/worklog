#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Seconds since the user last touched the keyboard or mouse (Windows: GetLastInputInfo). Elsewhere
// `available` is false and idleSeconds() is 0.
class IdleMonitor : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool available READ available CONSTANT)

public:
    explicit IdleMonitor(QObject *parent = nullptr) : QObject(parent) {}
    bool available() const;
    Q_INVOKABLE double idleSeconds() const;
};
