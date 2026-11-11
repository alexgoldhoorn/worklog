#include "secretstore.h"

#include <QSettings>

void SecretStore::removeLegacy(const QString &key)
{
    QSettings().remove(key);
}

#if defined(Q_OS_WIN)
#include <windows.h>
#include <wincred.h>

#include <string>

static std::wstring target(const QString &key)
{
    return (QStringLiteral("worklog/") + key).toStdWString();
}

SecretStore::SecretStore(QObject *parent) : QObject(parent) {}

QString SecretStore::get(const QString &key)
{
    PCREDENTIALW cred = nullptr;
    if (!CredReadW(target(key).c_str(), CRED_TYPE_GENERIC, 0, &cred))
        return QString();
    const QString v = QString::fromUtf16(reinterpret_cast<const char16_t *>(cred->CredentialBlob),
                                         qsizetype(cred->CredentialBlobSize / 2));
    CredFree(cred);
    return v;
}

bool SecretStore::set(const QString &key, const QString &value)
{
    if (value.isEmpty()) {
        remove(key);
        return true;
    }
    std::wstring t = target(key);
    std::wstring user = L"worklog";
    CREDENTIALW cred = {};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = const_cast<LPWSTR>(t.c_str());
    cred.UserName = const_cast<LPWSTR>(user.c_str());
    cred.CredentialBlobSize = DWORD(value.size() * 2);
    cred.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<QChar *>(value.constData()));
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&cred, 0) != FALSE;
}

void SecretStore::remove(const QString &key)
{
    CredDeleteW(target(key).c_str(), CRED_TYPE_GENERIC, 0);
}

#elif defined(Q_OS_ANDROID)
#include <QCoreApplication>
#include <QJniObject>

static const char *storeClass = "net/goldhoorn/worklog/SecretStore";

SecretStore::SecretStore(QObject *parent) : QObject(parent) {}

QString SecretStore::get(const QString &key)
{
    const QJniObject r = QJniObject::callStaticObjectMethod(
            storeClass, "get", "(Landroid/content/Context;Ljava/lang/String;)Ljava/lang/String;",
            QNativeInterface::QAndroidApplication::context().object(),
            QJniObject::fromString(key).object<jstring>());
    return r.isValid() ? r.toString() : QString();
}

bool SecretStore::set(const QString &key, const QString &value)
{
    if (value.isEmpty()) {
        remove(key);
        return true;
    }
    return QJniObject::callStaticMethod<jboolean>(
            storeClass, "set", "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z",
            QNativeInterface::QAndroidApplication::context().object(),
            QJniObject::fromString(key).object<jstring>(), QJniObject::fromString(value).object<jstring>());
}

void SecretStore::remove(const QString &key)
{
    QJniObject::callStaticMethod<void>(storeClass, "remove", "(Landroid/content/Context;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(),
                                       QJniObject::fromString(key).object<jstring>());
}

#else

SecretStore::SecretStore(QObject *parent) : QObject(parent) {}

QString SecretStore::get(const QString &key)
{
    return QSettings().value("secrets/" + key).toString();
}

bool SecretStore::set(const QString &key, const QString &value)
{
    QSettings s;
    if (value.isEmpty())
        s.remove("secrets/" + key);
    else
        s.setValue("secrets/" + key, value);
    return true;
}

void SecretStore::remove(const QString &key)
{
    QSettings().remove("secrets/" + key);
}

#endif
