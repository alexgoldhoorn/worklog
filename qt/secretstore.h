#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// Keeps small secrets (the login password) out of the plain-text settings store:
// Windows: Credential Manager. Android: an AES-GCM key in the Android Keystore encrypts the value
// (android/src/.../SecretStore.java). Elsewhere: QSettings (plain text, same as before).
class SecretStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit SecretStore(QObject *parent = nullptr);

    // "" when the key is missing (or cannot be read)
    Q_INVOKABLE QString get(const QString &key);
    // true when the value was stored; an empty value removes the key
    Q_INVOKABLE bool set(const QString &key, const QString &value);
    Q_INVOKABLE void remove(const QString &key);
    // deletes a key from the plain-text QSettings store (QML's Settings cannot), for the migration
    Q_INVOKABLE void removeLegacy(const QString &key);
};
