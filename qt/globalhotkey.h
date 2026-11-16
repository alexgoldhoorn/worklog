#pragma once

#include <QAbstractNativeEventFilter>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// A system-wide hotkey (Windows: RegisterHotKey + WM_HOTKEY). Elsewhere it does nothing:
// `error` then says it is unsupported. `error` is also set when another program owns the keys.
class GlobalHotkey : public QObject, public QAbstractNativeEventFilter
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString sequence READ sequence WRITE setSequence NOTIFY sequenceChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)   // "" when registered or disabled
    Q_PROPERTY(bool registered READ registered NOTIFY errorChanged)

public:
    explicit GlobalHotkey(QObject *parent = nullptr);
    ~GlobalHotkey() override;

    QString sequence() const { return m_sequence; }
    void setSequence(const QString &s);
    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QString error() const { return m_error; }
    bool registered() const { return m_registered; }

    bool nativeEventFilter(const QByteArray &eventType, void *message, qintptr *result) override;

signals:
    void activated();
    void sequenceChanged();
    void enabledChanged();
    void errorChanged();

private:
    void apply();
    void release();
    void setError(const QString &e);

    QString m_sequence = QStringLiteral("Ctrl+Alt+W");
    bool m_enabled = false;
    bool m_registered = false;
    QString m_error;
    int m_id = 0;
};
