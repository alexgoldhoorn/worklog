#if defined(WORKLOG_LIBSECRET)
// glib before any Qt header: glib uses `signals` as an identifier, which Qt defines as a macro
#include <libsecret/secret.h>
#endif

#include "secretstore.h"

#include <QCoreApplication>
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
    // The organisation name keeps the real app on "worklog/<key>"; tests and
    // WORKLOG_ORG scratch copies get their own entry.
    QString org = QCoreApplication::organizationName();
    if (org.isEmpty())
        org = QStringLiteral("worklog");
    return (org + QLatin1Char('/') + key).toStdWString();
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
#include <QJniEnvironment>
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
    const bool ok = QJniObject::callStaticMethod<jboolean>(
            storeClass, "set", "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z",
            QNativeInterface::QAndroidApplication::context().object(),
            QJniObject::fromString(key).object<jstring>(), QJniObject::fromString(value).object<jstring>());
    QJniEnvironment env;
    if (env.checkAndClearExceptions())   // a Java exception is a failed write too
        return false;
    return ok;
}

void SecretStore::remove(const QString &key)
{
    QJniObject::callStaticMethod<void>(storeClass, "remove", "(Landroid/content/Context;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(),
                                       QJniObject::fromString(key).object<jstring>());
}

#else

// Plain-text fallback (QSettings): the only store without libsecret, and the backup with it
static QString plainGet(const QString &key)
{
    return QSettings().value("secrets/" + key).toString();
}

static void plainSet(const QString &key, const QString &value)
{
    QSettings s;
    if (value.isEmpty())
        s.remove("secrets/" + key);
    else
        s.setValue("secrets/" + key, value);
}

SecretStore::SecretStore(QObject *parent) : QObject(parent) {}

#if defined(WORKLOG_LIBSECRET)
// Linux: the Secret Service (GNOME Keyring, KWallet). Without a running service (headless,
// a bare window manager) libsecret fails and the value goes to QSettings instead.
#include <QDebug>

static const SecretSchema *schema()
{
    static const SecretSchema s = {
        "net.goldhoorn.worklog", SECRET_SCHEMA_NONE,
        {{"key", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING}},
        0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    return &s;
}

// The "key" attribute: the bare key for the real app (organisation "worklog"), "<org>/<key>" for
// tests and WORKLOG_ORG scratch copies, so they never read or overwrite the real password.
static QByteArray attr(const QString &key)
{
    const QString org = QCoreApplication::organizationName();
    if (org.isEmpty() || org == QLatin1String("worklog"))
        return key.toUtf8();
    return (org + QLatin1Char('/') + key).toUtf8();
}

QString SecretStore::get(const QString &key)
{
    GError *err = nullptr;
    const QByteArray k = attr(key);
    gchar *pw = secret_password_lookup_sync(schema(), nullptr, &err, "key", k.constData(), nullptr);
    if (err)
        g_error_free(err);
    if (!pw)
        return plainGet(key);
    const QString v = QString::fromUtf8(pw);
    secret_password_free(pw);
    return v;
}

bool SecretStore::set(const QString &key, const QString &value)
{
    if (value.isEmpty()) {
        remove(key);
        return true;
    }
    GError *err = nullptr;
    const QByteArray k = attr(key), v = value.toUtf8();
    const QByteArray label = "WorkLog " + k;
    const bool ok = secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT, label.constData(),
                                               v.constData(), nullptr, &err, "key", k.constData(), nullptr);
    if (err) {
        qWarning() << "SecretStore: no keyring, keeping" << key << "in plain settings:" << err->message;
        g_error_free(err);
    }
    plainSet(key, ok ? QString() : value);
    return true;
}

void SecretStore::remove(const QString &key)
{
    const QByteArray k = attr(key);
    secret_password_clear_sync(schema(), nullptr, nullptr, "key", k.constData(), nullptr);
    plainSet(key, QString());
}

#else

QString SecretStore::get(const QString &key)
{
    return plainGet(key);
}

bool SecretStore::set(const QString &key, const QString &value)
{
    plainSet(key, value);
    return true;
}

void SecretStore::remove(const QString &key)
{
    plainSet(key, QString());
}

#endif
#endif
