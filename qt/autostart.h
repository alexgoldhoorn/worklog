#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// Windows: start with the user's session, minimised to the tray (HKCU ...\CurrentVersion\Run, value
// named after the application, command `"<exe>" --minimized`). `enabled` always reflects the registry.
// Elsewhere: `supported` is false. `startMinimized` is true when this process got --minimized.
class Autostart : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool startMinimized READ startMinimized CONSTANT)

public:
    explicit Autostart(QObject *parent = nullptr);

    bool supported() const;
    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QString error() const { return m_error; }
    bool startMinimized() const;

    Q_INVOKABLE void refresh();   // read the registry again

signals:
    void enabledChanged();
    void errorChanged();

private:
    QString valueName() const;
    QString command() const;
    void setError(const QString &e);

    bool m_enabled = false;
    QString m_error;
};
