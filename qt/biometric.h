#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// Fingerprint/face unlock, with the device's screen lock as fallback (Android: BiometricPrompt through
// android/src/.../Biometric.java). Elsewhere it is unavailable and authenticate() fails at once.
class Biometric : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Biometric(QObject *parent = nullptr);
    ~Biometric() override;

    // a fingerprint/face is enrolled or a screen lock is set
    Q_INVOKABLE bool isAvailable() const;
    // shows the system prompt; the answer comes as result()
    Q_INVOKABLE void authenticate(const QString &title, const QString &subtitle = QString());

signals:
    void result(bool ok, const QString &error);
};
