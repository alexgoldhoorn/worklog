#include "biometric.h"

#include <QMetaObject>
#include <QPointer>

static QPointer<Biometric> s_instance;

Biometric::~Biometric()
{
    if (s_instance == this)
        s_instance = nullptr;
}

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>

static const char *biometricClass = "net/goldhoorn/worklog/Biometric";

// Biometric.onResult(boolean, String), on Android's UI thread: hand it to the Qt thread
static void onResult(JNIEnv *, jclass, jboolean ok, jstring error)
{
    const QString e = QJniObject(error).toString();
    if (Biometric *b = s_instance.data())
        QMetaObject::invokeMethod(b, [b, ok, e] { emit b->result(ok, e); }, Qt::QueuedConnection);
}

Biometric::Biometric(QObject *parent) : QObject(parent)
{
    s_instance = this;
    static bool registered = false;
    if (!registered) {
        const JNINativeMethod methods[] = {
            { "onResult", "(ZLjava/lang/String;)V", reinterpret_cast<void *>(onResult) },
        };
        QJniEnvironment env;
        registered = env.registerNativeMethods(biometricClass, methods, 1);
    }
}

bool Biometric::isAvailable() const
{
    return QJniObject::callStaticMethod<jboolean>(biometricClass, "isAvailable", "(Landroid/content/Context;)Z",
                                                  QNativeInterface::QAndroidApplication::context().object());
}

void Biometric::authenticate(const QString &title, const QString &subtitle)
{
    QJniObject::callStaticMethod<void>(biometricClass, "authenticate",
                                       "(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(),
                                       QJniObject::fromString(title).object<jstring>(),
                                       QJniObject::fromString(subtitle).object<jstring>());
}

#else

Biometric::Biometric(QObject *parent) : QObject(parent)
{
    s_instance = this;
}

bool Biometric::isAvailable() const
{
    return false;
}

void Biometric::authenticate(const QString &, const QString &)
{
    QMetaObject::invokeMethod(this, [this] { emit result(false, tr("Not available on this device")); },
                              Qt::QueuedConnection);
}

#endif
